import Foundation

/// Serializes the two automatic connection sources that can run during app
/// startup: an explicitly injected attach URL and restoration of a saved Mac.
///
/// The coordinator lives above ``CMUXMobileRootView`` so repeated SwiftUI
/// lifecycle callbacks and root-view reconstruction observe the same owner.
/// Explicit launch routes remain consumed until authentication resets; stored
/// reconnects release ownership when their attempt finishes so a user retry can
/// start a fresh attempt.
@MainActor
final class MobileStartupConnectionCoordinator {
    struct Attempt: Equatable, Sendable {
        fileprivate let id: UUID
    }

    private enum Owner: Equatable {
        case unclaimed
        case injectedAttach(Attempt)
        case injectedAttachConsumed
        case storedReconnect(Attempt)
    }

    private var owner: Owner = .unclaimed

    func claimInjectedAttach() -> Attempt? {
        guard owner == .unclaimed else { return nil }
        let attempt = Attempt(id: UUID())
        owner = .injectedAttach(attempt)
        return attempt
    }

    func finishInjectedAttach(_ attempt: Attempt) {
        guard owner == .injectedAttach(attempt) else { return }
        owner = .injectedAttachConsumed
    }

    func claimStoredReconnect() -> Attempt? {
        guard owner == .unclaimed else { return nil }
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
