/// The stable identity and capabilities needed to select a default cloud machine.
public struct CloudMachineDescriptor: Equatable, Sendable {
    /// The control plane's immutable machine identifier.
    public let id: String
    /// Whether this machine supports the desktop experience.
    public let isDesktop: Bool

    /// Describes a machine independently of its user-editable display name.
    /// - Parameters:
    ///   - id: The control plane's machine identifier.
    ///   - isDesktop: Whether the machine supports a desktop.
    public init(id: String, isDesktop: Bool) {
        self.id = id
        self.isDesktop = isDesktop
    }
}
