public import AppKit
public import CmuxTheme

/// A machine's identity color: one of the theme's accents, picked by a
/// stable hash of the machine's name (trimmed, lowercased), so each machine
/// keeps one color on every row, tab and chip that names it. It is
/// AgentPresenceColor's pick over the name, which the agent pane's
/// machineColor.ts repeats, so the sidebar and the composer chip agree.
public nonisolated struct MachineColor: Sendable {
    /// The machine's name as cmux shows it.
    public let name: String

    public init(name: String) { self.name = name }

    private var presence: AgentPresenceColor {
        AgentPresenceColor(key: name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The color in `tokens`' palette.
    public func rgb(tokens: ThemeTokens) -> ThemeRGB { presence.rgb(tokens: tokens) }

    /// The color in the active theme scope.
    @MainActor public var color: NSColor { presence.color }
}
