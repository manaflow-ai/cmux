import Foundation

/// Answers a panel's permission requests for an engine without a prompt cmux
/// can show (``BrowserPageUIDelegate/page(_:requestPermission:)`` on a
/// Chromium page): the policy first, then the profile's remembered answers,
/// then the panel's prompt bar.
///
/// The result's ``BrowserPagePermissionDecision/prompt`` means *no answer*
/// (the question ended unanswered: navigation, panel closed). Such an engine
/// leaves the request unanswered rather than dismissing it: Chromium counts
/// dismissals toward blocking the site for days.
@MainActor
public final class BrowserPagePermissionCoordinator {
    public let policy: BrowserPagePermissionPolicy
    public let queue: BrowserPermissionPromptQueue
    private let store: (UUID) -> BrowserSitePermissionStore

    /// Creates a coordinator.
    /// - Parameters:
    ///   - policy: Which kinds ask, which are denied.
    ///   - queue: The panel's prompt bar queue.
    ///   - store: The remembered answers of a profile (by profile id).
    public init(
        policy: BrowserPagePermissionPolicy = BrowserPagePermissionPolicy(),
        queue: BrowserPermissionPromptQueue,
        store: @escaping (UUID) -> BrowserSitePermissionStore
    ) {
        self.policy = policy
        self.queue = queue
        self.store = store
    }

    /// Decides one request.
    /// - Parameters:
    ///   - request: The page's request.
    ///   - profileID: The panel's browser profile.
    ///   - sessionGrants: The creating session's grants for a session tab, else `nil`.
    /// - Returns: Grant, deny, or ``BrowserPagePermissionDecision/prompt`` for no answer.
    public func decide(
        _ request: BrowserPagePermissionRequest,
        profileID: UUID,
        sessionGrants: Set<String>?
    ) async -> BrowserPagePermissionDecision {
        switch policy.decide(request, sessionGrants: sessionGrants) {
        case .grant:
            return .grant
        case .deny:
            return .deny
        case .ask(let kinds):
            guard let origin = request.origin else { return .deny }
            let profileStore = store(profileID)
            let settings = kinds.map { profileStore.setting($0, for: origin) }
            if settings.contains(.block) { return .deny }
            if settings.allSatisfy({ $0 == .allow }) { return .grant }
            let answer = await ask(BrowserPermissionPrompt(kinds: kinds, origin: origin))
            switch answer {
            case .allowAndRemember?:
                profileStore.set(.allow, for: kinds, at: origin)
                return .grant
            case .allowOnce?:
                return .grant
            case .block?:
                profileStore.set(.block, for: kinds, at: origin)
                return .deny
            case nil:
                return .prompt
            }
        }
    }

    private func ask(_ prompt: BrowserPermissionPrompt) async -> BrowserPermissionPromptAnswer? {
        await withCheckedContinuation { continuation in
            queue.enqueue(prompt) { continuation.resume(returning: $0) }
        }
    }
}
