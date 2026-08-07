import Foundation

/// Serializes the two automatic connection sources that can run during app
/// startup: an explicitly injected attach URL and restoration of a saved Mac.
///
/// The coordinator lives above ``CMUXMobileRootView`` so repeated SwiftUI
/// lifecycle callbacks and root-view reconstruction observe the same owner.
/// Successful explicit routes remain consumed until authentication resets.
/// Failed explicit routes release startup to the saved-Mac reconnect instead
/// of stranding the authenticated shell in a disconnected state.
@MainActor
final class MobileStartupConnectionCoordinator {
    enum InjectedAttachOutcome: Sendable {
        case connected
        case awaitingUserApproval
        case failed
    }

    struct Attempt: Equatable, Sendable {
        fileprivate let id: UUID
    }

    private enum Owner: Equatable {
        case unclaimed
        case injectedAttach(Attempt)
        case injectedAttachConsumed
        case injectedAttachFailed
        case storedReconnect(Attempt)
    }

    private var owner: Owner = .unclaimed

    var shouldFallBackFromInjectedAttach: Bool {
        owner == .injectedAttachFailed
    }

    func claimInjectedAttach() -> Attempt? {
        guard owner == .unclaimed else { return nil }
        let attempt = Attempt(id: UUID())
        owner = .injectedAttach(attempt)
        return attempt
    }

    /// Completes an explicit launch attach.
    ///
    /// - Returns: Whether startup should fall back to the saved Mac.
    @discardableResult
    func finishInjectedAttach(
        _ attempt: Attempt,
        outcome: InjectedAttachOutcome
    ) -> Bool {
        guard owner == .injectedAttach(attempt) else { return false }
        switch outcome {
        case .connected, .awaitingUserApproval:
            owner = .injectedAttachConsumed
            return false
        case .failed:
            owner = .injectedAttachFailed
            return true
        }
    }

    /// Releases an in-flight explicit attach immediately. Late completion for
    /// the cancelled attempt is ignored by ``finishInjectedAttach(_:outcome:)``.
    @discardableResult
    func cancelInjectedAttach(_ attempt: Attempt) -> Bool {
        finishInjectedAttach(attempt, outcome: .failed)
    }

    func claimStoredReconnect() -> Attempt? {
        guard owner == .unclaimed || owner == .injectedAttachFailed else {
            return nil
        }
        let attempt = Attempt(id: UUID())
        owner = .storedReconnect(attempt)
        return attempt
    }

    func finishStoredReconnect(_ attempt: Attempt) {
        guard owner == .storedReconnect(attempt) else { return }
        owner = .unclaimed
    }

    func reset() {
        owner = .unclaimed
    }
}
