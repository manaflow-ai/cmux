/// A downloaded update that waits for Restart to Update: one click (the sidebar card, the
/// Command Palette) installs it and relaunches cmux (``UpdaterService/restartableUpdate``).
public struct RestartableUpdate: Sendable, Equatable {
    /// The staged build's version as the feed names it ("0.42.0 (1234)"), or nil when unknown.
    public let version: String?

    /// Makes the value for a staged update.
    /// - Parameter version: The staged build's version, nil when Sparkle did not name it.
    public init(version: String?) {
        self.version = version
    }

    /// "Restart to Update", localized: the sidebar card's button title, used by every entrypoint.
    public var title: String { UpdaterStrings.restartToUpdate }
}
