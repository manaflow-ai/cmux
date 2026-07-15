/// Debug-build transport policy used to verify each supported Iroh path class.
public enum CmxIrohTransportVerificationMode: String, Equatable, Sendable {
    /// Uses configured relays while allowing authenticated direct-path activation.
    case automatic

    /// Uses configured relays and prevents authenticated direct-path activation.
    case relayOnly

    /// Disables Iroh relay listening and dialing while retaining direct paths.
    case directOnly

    /// Shared defaults key used by the macOS and iOS debug composition roots.
    public static let debugDefaultsKey = "cmux.iroh.debug.transport-mode"

    /// Whether an admitted connection may activate and migrate to direct paths.
    public var allowsNATTraversalAfterAdmission: Bool {
        self != .relayOnly
    }
}
