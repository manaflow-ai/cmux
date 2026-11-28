public import Foundation

/// Icon of a tab bar button or config action from cmux.json.
public enum ConfigIcon: Sendable, Hashable {
    /// An SF Symbol name.
    case symbol(String)
    /// An image file; relative config paths are resolved against the
    /// directory of cmux.json.
    case image(URL)
}

/// A cmux.json `actions.<name>` entry that types a command into a terminal
/// (`type: "command"` or `type: "agent"`). The App registers each one in the
/// action registry under `actionID`, so buttons, the palette, shortcuts and
/// the CLI all run it through the same path.
public struct ConfigCommandAction: Sendable, Hashable, Identifiable {
    /// Where the command runs.
    public enum Target: String, Sendable, Hashable {
        /// A new terminal tab in the targeted pane (the default).
        case newTabInCurrentPane
        /// The targeted pane's selected terminal.
        case currentTerminal
    }

    /// Registry ID (`cmuxConfig.<name>`).
    public var actionID: String
    /// Key under `actions`, or the button id for an inline command button.
    public var name: String
    public var title: String
    public var tooltip: String?
    public var icon: ConfigIcon?
    /// Shell text typed into the terminal, followed by Return.
    public var command: String
    public var target: Target

    public var id: String { actionID }

    public init(name: String, title: String, tooltip: String? = nil, icon: ConfigIcon? = nil,
                command: String, target: Target = .newTabInCurrentPane) {
        self.actionID = Self.actionID(forName: name)
        self.name = name
        self.title = title
        self.tooltip = tooltip
        self.icon = icon
        self.command = command
        self.target = target
    }

    /// Prefix of every registry ID made from cmux.json actions.
    public static let actionIDPrefix = "cmuxConfig."

    public static func actionID(forName name: String) -> String { actionIDPrefix + name }
}
