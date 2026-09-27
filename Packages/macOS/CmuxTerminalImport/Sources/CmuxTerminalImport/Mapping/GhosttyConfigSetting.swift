/// One `key = value` line cmux import writes to cmux's Ghostty config.
public struct GhosttyConfigSetting: Equatable, Sendable {
    /// The Ghostty config key, such as `font-family`.
    public var key: String
    /// The value exactly as written after `=`.
    public var value: String

    /// Creates a setting.
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
