/// A live sibling cmux build found on this Mac and the sessions it can hand over.
public nonisolated struct SessionTransferPeer: Sendable {
    /// The build's control socket path, what a pull names as its source.
    public let path: String
    /// The build's app name (`cmux DEV`, `cmux NIGHTLY`, ...).
    public let app: String
    /// The build's version or build number.
    public let build: String
    /// The build's tag, when it is a tagged dev build.
    public let tag: String?
    /// The build's process id.
    public let pid: Int32
    /// The sessions the build offers.
    public let items: [SessionTransferItem]

    /// Creates a peer from what its socket reported.
    /// - Parameters:
    ///   - path: The control socket path.
    ///   - app: The app name.
    ///   - build: The build number.
    ///   - tag: The dev build tag, if any.
    ///   - pid: The process id.
    ///   - items: The sessions it offers.
    public init(path: String, app: String, build: String, tag: String?, pid: Int32, items: [SessionTransferItem]) {
        self.path = path
        self.app = app
        self.build = build
        self.tag = tag
        self.pid = pid
        self.items = items
    }
}
