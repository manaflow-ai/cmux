/// One forwardable port in `tunnel.ports`.
public struct TunnelPort: Hashable, Sendable, Codable {
    public var port: UInt16
    public var source: TunnelPortSource
    /// The workspace (`ws_…`) whose process listens, when detected.
    public var workspace: String?
    /// The listening process name, when detected.
    public var process: String?

    public init(port: UInt16, source: TunnelPortSource, workspace: String? = nil, process: String? = nil) {
        self.port = port
        self.source = source
        self.workspace = workspace
        self.process = process
    }
}
