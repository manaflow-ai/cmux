/// A pane's marker color (`pane.setTint`): a named color or `#RRGGBB`, washed over the pane so
/// agent and person panes, or prod and dev, tell apart at a glance.
///
/// ```swift
/// PaneTint("purple")?.id   // "purple"
/// PaneTint("#ff8800")?.id  // "#FF8800"
/// ```
public nonisolated struct PaneTint: Equatable, Hashable, Sendable {
    /// Red, 0...1.
    public let red: Double
    /// Green, 0...1.
    public let green: Double
    /// Blue, 0...1.
    public let blue: Double
    /// The persisted value: the color's name, or `#RRGGBB`.
    public let id: String

    /// The named marker colors, in menu order (macOS system colors, dark-mode values).
    public static let named: [(name: String, rgb: (Double, Double, Double))] = [
        ("red", (1.0, 0.271, 0.227)), ("orange", (1.0, 0.624, 0.039)), ("yellow", (1.0, 0.839, 0.039)),
        ("green", (0.188, 0.820, 0.345)), ("teal", (0.251, 0.784, 0.878)), ("blue", (0.039, 0.518, 1.0)),
        ("purple", (0.749, 0.353, 0.949)), ("pink", (1.0, 0.216, 0.373)), ("gray", (0.596, 0.596, 0.616)),
    ]

    /// Parses a named color or `#RRGGBB`; nil for anything else (`none` clears, and is not a tint).
    ///
    /// - Parameter text: The value from a menu, the CLI or the store.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let named = Self.named.first(where: { $0.name == trimmed.lowercased() }) {
            (red, green, blue) = named.rgb
            id = named.name
            return
        }
        guard trimmed.hasPrefix("#"), trimmed.count == 7, let value = UInt32(trimmed.dropFirst(), radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
        id = "#" + String(trimmed.dropFirst()).uppercased()
    }
}
