/// The local auth states that matter to the Cloud Machines panel. Keeping the
/// projection here means the panel never has to infer auth from a failed VM
/// request (which could otherwise briefly leave stale machine rows visible).
public enum CloudVMPanelAuthState: Equatable, Sendable {
    case checking
    case signedOut
    case signedIn

    public static func resolve(isAuthenticated: Bool, isWorkingOnAuth: Bool) -> Self {
        if isAuthenticated { return .signedIn }
        if isWorkingOnAuth { return .checking }
        return .signedOut
    }

    /// Whether a native Cloud VM operation may start in this state.
    public var allowsAuthenticatedOperation: Bool {
        self == .signedIn
    }
}
