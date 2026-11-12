/// The two separately keyed peers belonging to one saved device identity.
public enum CloudTunnelPurpose: String, Sendable, CaseIterable {
    case terminal
    /// The system VPN also lets Safari and other apps reach private ports.
    case browser
}
