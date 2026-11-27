/// How the App launches an app target of ``TerminalLinkOpener`` for one URL.
public nonisolated struct TerminalLinkOpenerLaunch: Sendable, Hashable {
    /// The app: a name (`Google Chrome`), a bundle ID or a `.app` path, resolved by the App.
    public var app: String
    /// Launch arguments, which then carry the URL. Empty: the URL is opened with the app.
    public var arguments: [String]
    /// True when the arguments need a new instance (a running app drops a plain open's arguments).
    public var newInstance: Bool

    public init(app: String, arguments: [String], newInstance: Bool) {
        self.app = app
        self.arguments = arguments
        self.newInstance = newInstance
    }
}
