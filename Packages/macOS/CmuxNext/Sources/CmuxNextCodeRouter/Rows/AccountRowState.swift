import Foundation

/// The state of one provider row on the Accounts screen, driven only by
/// ``AccountRowState/reduce(_:)``. Pure value: the UI model feeds events
/// from detection and the user's buttons.
public struct AccountRowState: Sendable, Equatable {
    /// The one operation a row runs at a time.
    public enum Phase: Sendable, Equatable {
        case idle
        case detecting
        /// The provider's own login runs in a terminal or browser tab.
        case reauthenticating
    }

    /// The last operation's outcome, shown under the row until the next one.
    public enum Outcome: Sendable, Equatable {
        case failed(String)
    }

    public let provider: AIProvider
    public private(set) var detection: ProviderDetection?
    public private(set) var phase: Phase = .detecting
    public private(set) var outcome: Outcome?

    public init(provider: AIProvider) {
        self.provider = provider
    }

    public enum Event: Sendable, Equatable {
        case detectionStarted
        case detected(ProviderDetection)
        case reauthStarted
        case reauthEnded
        /// The login or logout never opened (no local pane): free the row.
        case reauthFailed(String)
    }

    /// Applies one event. Events that do not fit the current phase (a
    /// second login while one runs, a stale reply) change nothing.
    public mutating func reduce(_ event: Event) {
        switch event {
        case .detectionStarted:
            if phase == .idle { phase = .detecting }
        case .detected(let result):
            guard result.provider == provider else { return }
            detection = result
            if phase == .detecting || phase == .reauthenticating { phase = .idle }
        case .reauthStarted:
            guard phase == .idle, canReauthenticate || canSignOut else { return }
            phase = .reauthenticating
            outcome = nil
        case .reauthEnded:
            if phase == .reauthenticating { phase = .detecting }
        case .reauthFailed(let message):
            guard phase == .reauthenticating else { return }
            phase = .idle
            outcome = .failed(message)
        }
    }

    // MARK: Derived

    public var status: LocalAuthStatus? { detection?.status }

    public var isBusy: Bool { phase != .idle }

    public var canReauthenticate: Bool { provider.reauthPlan != .none }

    /// Sign Out runs the provider's logout: only for a sign-in the logout
    /// removes, the CLI's own file or Keychain item
    /// (``AIProvider/signOutRemoves(_:)``). A shell variable is not the CLI's
    /// to remove; ``shellVariableInUse`` names it instead.
    public var canSignOut: Bool {
        guard provider.signOutPlan != .none, status == .signedIn || status == .expired else { return false }
        return detection?.sources.contains(where: provider.signOutRemoves) == true
    }

    /// The shell variable the sign-in comes from (`$CLAUDE_CODE_OAUTH_TOKEN`),
    /// for a provider whose CLI it overrides: while it is set, the CLI uses
    /// it and ignores a re-authentication or a sign-out made here.
    public var shellVariableInUse: String? {
        guard provider.signOutPlan != .none, status == .signedIn || status == .expired, let first = detection?.sources.first,
              first.isEnvironment else { return nil }
        return first.label
    }

    /// The local sign-in is a model provider of the CLI's own config (sr, a
    /// router, a local server), not a sign-in of the provider itself.
    public var usesProviderConfig: Bool {
        guard let sources = detection?.sources else { return false }
        return sources.contains { source in
            if case .providerConfig = source { return true }
            return false
        }
    }
}
