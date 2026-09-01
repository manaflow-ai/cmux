import Foundation

/// Serializes the automatic connection sources that can run during app
/// startup: an explicitly injected attach URL and restoration of a saved Mac
/// (including the pre-bootstrap early dial against the restored keychain
/// session).
///
/// The coordinator lives above the mobile root view so repeated SwiftUI
/// lifecycle callbacks and root-view reconstruction observe the same owner.
/// Successful explicit routes remain consumed until authentication resets.
/// Failed explicit routes release startup to the saved-Mac reconnect instead
/// of stranding the authenticated shell in a disconnected state.
///
/// It lives in `CmuxMobileShellModel` (not the iOS-only shell UI package) so
/// its ownership ordering runs under `swift test` on macOS.
@MainActor
public final class MobileStartupConnectionCoordinator {
    private struct AccountScope: Equatable {
        let userID: String
        let teamID: String?
    }

    public enum InjectedAttachOutcome: Sendable {
        case connected
        case awaitingUserApproval
        case failed
    }

    public struct Attempt: Equatable, Sendable {
        fileprivate let id: UUID
    }

    public struct InjectedAttachCompletion: Equatable, Sendable {
        public let attempt: Attempt
        public let result: MobilePairingURLConnectionResult
        public let shouldReconnectStoredMac: Bool
    }

    private enum Owner: Equatable {
        case unclaimed
        case injectedAttach(Attempt)
        case injectedAttachConsumed
        case injectedAttachFailed
        case storedReconnect(Attempt)
    }

    private var owner: Owner = .unclaimed
    private var preparedAccountScope: AccountScope?
    private var injectedAttachTask: Task<Void, Never>?
    private var injectedAttachTaskAttempt: Attempt?

    public init() {}

    public var shouldFallBackFromInjectedAttach: Bool {
        owner == .injectedAttachFailed
    }

    /// Applies each authenticated account/team scope once before startup may
    /// dial. SwiftUI can deliver the bootstrap task and the matching `onChange`
    /// callback in either order; coalescing them here prevents the later
    /// callback from invalidating a healthy in-flight Iroh admission.
    ///
    /// The pre-bootstrap early dial applies the RESTORED keychain identity
    /// here first; when the auth bootstrap later resolves the SAME account and
    /// team, its duplicate application coalesces and the early connection
    /// survives. A bootstrap that resolves a DIFFERENT account or team is a
    /// genuine transition: the reset below supersedes the early startup owner
    /// and `apply` re-scopes the store.
    ///
    /// - Returns: `nil` when no authenticated account is available, otherwise
    ///   whether this call applied a new scope.
    @discardableResult
    public func prepareAccountScope(
        userID: String?,
        teamID: String?,
        apply: () -> Void
    ) -> Bool? {
        guard let userID, !userID.isEmpty else { return nil }
        let scope = AccountScope(userID: userID, teamID: teamID)
        guard preparedAccountScope != scope else { return false }

        // A genuine account/team transition supersedes startup work authorized
        // under the previous scope. The initial bootstrap reaches this before
        // any dial; a delayed duplicate is coalesced above.
        resetConnectionOwner()
        preparedAccountScope = scope
        apply()
        return true
    }

    public func claimInjectedAttach() -> Attempt? {
        guard owner == .unclaimed else { return nil }
        let attempt = Attempt(id: UUID())
        owner = .injectedAttach(attempt)
        return attempt
    }

    public func connectInjectedAttach(
        _ attempt: Attempt,
        attachURL: String,
        connect: @MainActor @Sendable (String) async -> MobilePairingURLConnectionResult
    ) async -> InjectedAttachCompletion? {
        guard owner == .injectedAttach(attempt),
              !Task.isCancelled else {
            return nil
        }
        let result = await connect(attachURL)
        guard owner == .injectedAttach(attempt),
              !Task.isCancelled else {
            return nil
        }
        let outcome: InjectedAttachOutcome =
            switch result {
            case .connected:
                .connected
            case .needsUserApproval:
                .awaitingUserApproval
            case .failed, .superseded:
                .failed
            }
        let shouldReconnectStoredMac = finishInjectedAttach(
            attempt,
            outcome: outcome
        )
        return InjectedAttachCompletion(
            attempt: attempt,
            result: result,
            shouldReconnectStoredMac: shouldReconnectStoredMac
        )
    }

    /// Starts the one-shot launch attach under the app-lifetime coordinator.
    /// Repeated root mounts consume the same route without replacing a healthy
    /// in-flight transport connection.
    @discardableResult
    public func startInjectedAttach(
        attachURL: String,
        prepare: @escaping @MainActor @Sendable () async -> Void,
        connect: @escaping @MainActor @Sendable (
            String
        ) async -> MobilePairingURLConnectionResult,
        onCompletion: @escaping @MainActor @Sendable (
            InjectedAttachCompletion
        ) -> Void
    ) -> Bool {
        if shouldFallBackFromInjectedAttach {
            return false
        }
        if injectedAttachTask != nil {
            return true
        }
        guard let attempt = claimInjectedAttach() else {
            return true
        }
        injectedAttachTaskAttempt = attempt
        injectedAttachTask = Task { @MainActor [weak self] in
            await prepare()
            guard let self, !Task.isCancelled else { return }
            let completion = await self.connectInjectedAttach(
                attempt,
                attachURL: attachURL,
                connect: connect
            )
            guard !Task.isCancelled,
                  self.injectedAttachTaskAttempt == attempt else {
                return
            }
            self.injectedAttachTask = nil
            self.injectedAttachTaskAttempt = nil
            guard let completion else { return }
            onCompletion(completion)
        }
        return true
    }

    /// Completes an explicit launch attach.
    ///
    /// - Returns: Whether startup should fall back to the saved Mac.
    @discardableResult
    public func finishInjectedAttach(
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

    /// Releases an in-flight explicit attach immediately. Retryable releases
    /// keep a DEBUG launch attach URL available after transient SwiftUI
    /// teardown, while terminal failures fall through to stored-Mac reconnect.
    /// Late completion for the cancelled attempt is ignored by
    /// ``finishInjectedAttach(_:outcome:)``.
    @discardableResult
    public func cancelInjectedAttach(
        _ attempt: Attempt,
        retryLaunchRoute: Bool = false
    ) -> Bool {
        guard owner == .injectedAttach(attempt) else { return false }
        if injectedAttachTaskAttempt == attempt {
            injectedAttachTask?.cancel()
            injectedAttachTask = nil
            injectedAttachTaskAttempt = nil
        }
        if retryLaunchRoute {
            owner = .unclaimed
            return false
        }
        owner = .injectedAttachFailed
        return true
    }

    public func claimStoredReconnect() -> Attempt? {
        guard owner == .unclaimed || owner == .injectedAttachFailed else {
            return nil
        }
        let attempt = Attempt(id: UUID())
        owner = .storedReconnect(attempt)
        return attempt
    }

    public func finishStoredReconnect(_ attempt: Attempt) {
        guard owner == .storedReconnect(attempt) else { return }
        owner = .unclaimed
    }

    public func reset() {
        preparedAccountScope = nil
        resetConnectionOwner()
    }

    private func resetConnectionOwner() {
        injectedAttachTask?.cancel()
        injectedAttachTask = nil
        injectedAttachTaskAttempt = nil
        owner = .unclaimed
    }
}
