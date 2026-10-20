/// The local lifecycle role of a byte-transport request.
///
/// This value never crosses the network. Transport pools use it to keep
/// foreground diagnostics anchored to the user-visible RPC connection when
/// background aggregation or feature lanes share the same endpoint.
public enum CmxTransportSessionPurpose: UInt8, Equatable, Sendable {
    /// The control session powering the currently visible Mac workspace.
    case foregroundControl = 1
    /// A control session keeping a non-selected Mac's workspace list current.
    case backgroundControl = 2
    /// A short-lived request that discovers or validates a route.
    case probe = 3
    /// An independent feature lane sharing an admitted Iroh session.
    case featureLane = 4
}
