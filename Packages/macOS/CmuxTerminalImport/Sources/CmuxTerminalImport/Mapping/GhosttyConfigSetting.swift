/// One Ghostty config key cmux import writes, with the value line(s) it gets.
///
/// Most keys take one value. `font-family` is a list, so the import writes a
/// reset (`""`) followed by the family: the imported font then replaces the
/// user's font list instead of being appended to it as a fallback.
public struct GhosttyConfigSetting: Equatable, Sendable {
    /// The Ghostty config key, such as `font-family`.
    public var key: String
    /// The values exactly as written after `=`, one config line each, in order.
    public var values: [String]

    /// Creates a single-value setting.
    public init(key: String, value: String) {
        self.init(key: key, values: [value])
    }

    /// Creates a setting written as several lines, in order.
    public init(key: String, values: [String]) {
        self.key = key
        self.values = values
    }
}
