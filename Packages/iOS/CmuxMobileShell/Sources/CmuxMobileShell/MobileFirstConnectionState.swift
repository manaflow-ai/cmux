/// Connection choices available to a signed-in installation before its first attach.
public struct MobileFirstConnectionState: Equatable, Sendable {
    /// Whether the account already has a saved computer available locally or from backup.
    public let hasSavedComputer: Bool
    /// State of the account-private live-session projection in the team registry.
    public let registryState: MobileFirstConnectionRegistryState

    /// Creates the authoritative inputs for first-connection presentation.
    /// - Parameters:
    ///   - hasSavedComputer: Whether a saved computer is available.
    ///   - registryState: Current registry response state.
    public init(
        hasSavedComputer: Bool,
        registryState: MobileFirstConnectionRegistryState
    ) {
        self.hasSavedComputer = hasSavedComputer
        self.registryState = registryState
    }

    /// Whether the app may automatically present manual pairing.
    ///
    /// Automatic pairing is allowed only after the registry authoritatively
    /// confirms there is no saved computer and no account-private live session.
    public var shouldPresentManualPairing: Bool {
        guard !hasSavedComputer,
              case .loaded(hasAccountSession: false) = registryState else {
            return false
        }
        return true
    }

    /// Whether an automatically presented pairing sheet should be dismissed.
    ///
    /// Loading and transient unavailability preserve the user's in-progress form
    /// or scanner. Only a saved computer, an account session, or an authoritative
    /// scope rejection replaces the empty-registry state that opened the sheet.
    public var shouldDismissAutomaticPairing: Bool {
        if hasSavedComputer { return true }
        switch registryState {
        case .loaded(hasAccountSession: true), .authRejected:
            return true
        case .loading, .unavailable, .loaded(hasAccountSession: false):
            return false
        }
    }
}
