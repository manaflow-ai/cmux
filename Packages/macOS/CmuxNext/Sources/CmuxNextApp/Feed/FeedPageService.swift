import struct CmuxSafeConcurrency.OwnerReference
import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextFeed
import CmuxNextHibernation
import CmuxNextIcons
import Foundation

extension InternalPageID {
    /// The wide inbox view of the one feed model.
    static let inbox = InternalPageID(rawValue: "inbox")
}

/// Owns the wide Inbox page. It is a view on `FeedService.model`, not a
/// second store, and therefore shares owner events, triage intents and the
/// menu-bar feed panel.
@MainActor
final class FeedPageService: InternalPageProvider {
    private let servicesReference: OwnerReference<AppServices>
    /// The app's services, which own this; nil (reported) only once they are gone.
    private var services: AppServices? { servicesReference.resolve() }
    /// Sends report replies off the main thread.
    private let replies: AcpmuxReplySender
    /// Each tab's view while it has one, for its keep reasons.
    private var hosts: [String: FeedHostView] = [:]

    init(services: AppServices, replies: AcpmuxReplySender = AcpmuxReplySender()) {
        servicesReference = OwnerReference(services: services)
        self.replies = replies
    }

    /// Opens the Inbox in the active window without activating it for agent
    /// or socket callers when `focus` is false.
    func open(focus: Bool) throws {
        guard let services else { throw ActionFailure.appClosing }
        guard let window = services.windows.active else { throw ActionFailure(message: RefusalStrings.noWindowOpen) }
        services.feed.startIfSignedIn()
        guard services.pages.show(.inbox, in: window, focus: focus) != nil else {
            throw ActionFailure(message: RefusalStrings.noWindowOpen)
        }
    }

    var page: InternalPageID { .inbox }
    var title: String { FeedHostView.paneTitle }
    var symbol: String { "tray" }
    var icon: IconName? { .inbox }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services else { return NSView() }
        let feed = services.feed
        FeedGitHubActions.install(on: feed.model, services: services)
        let layout: FeedLayout = FeedTunables.reportsBasket.value ? .reportsBasket : .inbox
        let replies = replies
        // Resolved once at startup: a reply runs no executable lookup or signature check.
        let environment = feed.acpmuxEnvironment
        let host = FeedHostView(model: feed.model, layoutOverride: layout, mainWork: services.mainWork, surfaces: feed.surfaces) { reply in
            // A report poster's authenticated identity is its ACP session. A
            // human reply intentionally wakes that session, unlike delivery
            // into the reports basket. The feed owner remains the source of
            // report rows; the command is a bounded local adapter for Labs.
            // The process runs off the main thread, to its exit or deadline (AcpmuxReplySender).
            await replies.send(session: reply.session, text: reply.text, promptID: reply.promptID, environment: environment)
        }
        hosts[key] = host
        return host
    }

    func tabClosed(_ key: String) { hosts[key] = nil }

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// Ten minutes hidden, as a browser tab (Chrome's proactive_discarding_policy.cc). The view
    /// shows the one feed model, which stays with its drafts, so the next view shows the same items.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// The reports basket's reply typed and not sent, or sent and not answered, keeps the view.
    func keepReasons(for key: String) -> [CannotDiscardReason] {
        guard let host = hosts[key] else { return [] }
        var reasons: [CannotDiscardReason] = []
        if host.hasTypedReply { reasons.append(.unsavedEdits) }
        if host.isSendingReply { reasons.append(.inProgress) }
        return reasons
    }

    func viewDiscarded(_ key: String) { hosts[key] = nil }
}
