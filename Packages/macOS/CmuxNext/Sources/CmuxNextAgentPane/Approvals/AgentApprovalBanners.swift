import Foundation
public import UserNotifications

/// One agent chat permission prompt a banner can answer (cx-kz6m0.2): the only pending prompt
/// of a chat on this Mac's acpmux, read when its "needs input" banner posts.
public nonisolated struct AgentApproval: Sendable, Equatable {
    public var session: String
    public var permission: String
    /// sha256 of the prompt's request (``AcpmuxPermissionPrompt/digest(_:)``): an answer counts
    /// only while the same request is pending.
    public var digest: String
    /// What the agent asks to do (its tool call's title and command, scrubbed): the banner's body.
    public var summary: String

    public init(session: String, permission: String, digest: String, summary: String) {
        (self.session, self.permission, self.digest, self.summary) = (session, permission, digest, summary)
    }
}

/// Reads and answers an agent chat's permission prompt for its banner's Allow once and Deny.
/// The app's own is ``AcpmuxApprovalAnswerer``; tests stand in.
@MainActor
public protocol AgentApprovalAnswering: AnyObject {
    /// The chat's one pending tool permission that offers allow once and a deny; nil otherwise
    /// (no prompt, a question, several prompts, or no acpmux to ask).
    func pendingApproval(session: String) async -> AgentApproval?
    /// Answers `approval` (allow once, else deny) while it is still pending unchanged; false
    /// when nothing was answered.
    func answer(_ approval: AgentApproval, allow: Bool) async -> Bool
}

/// The approval banners of this launch, by tab (cx-kz6m0.2). A banner waits for its chat's
/// prompt read; a read the tab outlived (read meanwhile, or notified again) posts nothing. A
/// newer banner on a tab retires the older one's buttons, so each tab holds at most one.
@MainActor
public final class AgentApprovalBanners {
    public var answerer: (any AgentApprovalAnswering)?
    private var banners: [String: (approval: AgentApproval, tab: String)] = [:]
    /// Per tab id, the notification whose banner waits for its prompt read.
    private var reads: [String: UInt64] = [:]

    public init() {}

    /// Reads `session`'s prompt for notification `id` on `tab`, then posts with it unless the tab
    /// was read or notified again meanwhile, or `stillUnread` says the notification was read.
    public func read(session: String, notification id: UInt64, tab: String, stillUnread: @escaping @MainActor () -> Bool,
                     post: @escaping @MainActor (AgentApproval?) -> Void) {
        guard let answerer else { return post(nil) }
        reads[tab] = id
        // task-owner: AgentApprovalBanners.read: one prompt read before one banner posts.
        // main-hop-allow: pendingApproval is the answerer's main-actor async read (one acpmux connection whose lines decode off main and land in batches, MainActorLineBatch); the task only starts it and posts the banner it answers
        Task { [weak self] in
            let approval = await answerer.pendingApproval(session: session)
            guard let self, self.reads[tab] == id else { return }
            self.reads[tab] = nil
            if stillUnread() { post(approval) }
        }
    }

    /// `tab` posted a banner without a read, or (`retire`) was read: a read in flight posts
    /// nothing, and a read tab's approval banners answer nothing.
    public func forget(tab: String, retire: Bool) {
        reads[tab] = nil
        if retire { banners = banners.filter { $0.value.tab != tab } }
    }

    /// A banner posted on `tab`: it retires the tab's older approval banners and keeps its own.
    public func keep(_ banner: String, approval: AgentApproval?, tab: String) {
        banners = banners.filter { $0.value.tab != tab }
        if let approval { banners[banner] = (approval, tab) }
    }

    /// The prompt and tab of approval banner `banner`, once: nil for any other banner.
    public func take(_ banner: String) -> (approval: AgentApproval, tab: String)? {
        banners.removeValue(forKey: banner)
    }

    public nonisolated static let category = "cmux.notification.approval"
    public nonisolated static let allowAction = "cmux.notification.approval.allow-once"
    public nonisolated static let denyAction = "cmux.notification.approval.deny"

    /// The banners' category: Allow once (the Mac must be unlocked: an allow runs what the agent
    /// asked for) and Deny (destructive). Where macOS hides previews, the command stays hidden.
    public nonisolated static func notificationCategory() -> UNNotificationCategory {
        let allow = UNNotificationAction(identifier: allowAction, title: String(
            localized: "notifications.approval.allowOnce", defaultValue: "Allow once", bundle: .module), options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: denyAction, title: String(
            localized: "notifications.approval.deny", defaultValue: "Deny", bundle: .module), options: [.destructive])
        let hidden = String(localized: "notifications.approval.hiddenBody", defaultValue: "An agent is waiting for your approval", bundle: .module)
        return UNNotificationCategory(identifier: category, actions: [allow, deny], intentIdentifiers: [],
                                      hiddenPreviewsBodyPlaceholder: hidden, options: [])
    }

    /// A banner action's answer: true for Allow once, false for Deny, nil for any other action.
    public nonisolated static func decision(_ action: String) -> Bool? {
        action == allowAction ? true : action == denyAction ? false : nil
    }
}
