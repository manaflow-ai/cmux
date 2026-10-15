public import Foundation

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
        await decideDetailed(request, profileID: profileID, sessionGrants: sessionGrants).decision
    }

    /// A decision and whether a grant holds for this request only.
    public struct Outcome: Equatable, Sendable {
        public var decision: BrowserPagePermissionDecision
        /// The engine must not keep the grant ("Allow this time", a session
        /// tab's grant). Chromium saves every accepted prompt in its own
        /// content settings, so the Chromium adapter resets the kinds to
        /// "ask" for the origin right after accepting.
        public var isOneTime: Bool

        public init(_ decision: BrowserPagePermissionDecision, isOneTime: Bool = false) {
            self.decision = decision
            self.isOneTime = isOneTime
        }
    }

    /// Decides one request, reporting grants the engine must not keep.
    public func decideDetailed(
        _ request: BrowserPagePermissionRequest,
        profileID: UUID,
        sessionGrants: Set<String>?
    ) async -> Outcome {
        switch policy.decide(request, sessionGrants: sessionGrants) {
        case .grant:
            return Outcome(.grant, isOneTime: true)
        case .deny:
            return Outcome(.deny)
        case .ask(let kinds):
            guard let origin = request.origin else { return Outcome(.deny) }
            let profileStore = store(profileID)
            let settings = kinds.map { profileStore.setting($0, for: origin) }
            if settings.contains(.block) { return Outcome(.deny) }
            if settings.allSatisfy({ $0 == .allow }) { return Outcome(.grant) }
            let answer = await ask(BrowserPermissionPrompt(kinds: kinds, origin: origin))
            switch answer {
            case .allowAndRemember?:
                profileStore.set(.allow, for: kinds, at: origin)
                return Outcome(.grant)
            case .allowOnce?:
                return Outcome(.grant, isOneTime: true)
            case .block?:
                profileStore.set(.block, for: kinds, at: origin)
                return Outcome(.deny)
            case nil:
                return Outcome(.prompt)
            }
        }
    }

    private func ask(_ prompt: BrowserPermissionPrompt) async -> BrowserPermissionPromptAnswer? {
        await withCheckedContinuation { continuation in
            queue.enqueue(prompt) { continuation.resume(returning: $0) }
        }
    }
}
