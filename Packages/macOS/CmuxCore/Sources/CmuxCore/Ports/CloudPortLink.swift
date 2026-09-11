/// Describes the VM port and the local URL that reaches it on this Mac.
public struct CloudPortLink: Equatable, Sendable {
    /// The service port inside the Cloud VM.
    public let remotePort: Int
    /// The URL a browser on this Mac can load.
    public let url: String
    /// The VM's private address URL, when the machine has one.
    public let privateURL: String?
    /// The app-owned loopback listener, when the link uses a local forward.
    public let localPort: UInt16?

    /// Creates a Cloud port link description.
    public init(remotePort: Int, url: String, privateURL: String?, localPort: UInt16?) {
        self.remotePort = remotePort
        self.url = url
        self.privateURL = privateURL
        self.localPort = localPort
    }
}
