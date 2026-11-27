/// The sound a notification plays and how loud, after every level had its say.
public nonisolated struct NotificationSoundChoice: Hashable, Sendable {
    /// A sound name (``NotificationSoundLibrary``), a file path, or `"default"` (the banner's own sound).
    public var name: String
    /// 0 to 1: the deciding level's volume times the master volume.
    public var volume: Double
    /// The level that chose the sound (`agent:claude`, `workspace:ws_1`, `group:Ops`, `event`, `global`),
    /// for the debug log and `cmux notification explain-sound`.
    public var level: String

    public init(name: String, volume: Double = 1, level: String = "global") {
        self.name = name
        self.volume = volume
        self.level = level
    }
}
