/// Errors a `LinkTerminalByteSource` call throws.
public enum TerminalLinkError: Error, Hashable, Sendable {
    /// No attached channel: input is never queued offline.
    case notConnected
}
