/// The agent acting in a tab right now (cx-gg84), as the strip shows it.
public struct TabPresence: Hashable, Sendable {
    /// What an agent drives, drawn as a glyph instead of the dot: the screen (Computer Use) or a browser.
    public enum Drive: String, Hashable, Sendable {
        case screen, browser

        /// The SF Symbol the tab chip and the pane tag draw (the sidebar row's glyph too).
        public var symbol: String {
            switch self {
            case .screen: "display"
            case .browser: "globe"
            }
        }
    }

    /// The agent's color key (its session id), for `AgentPresenceColor`.
    public var colorKey: String
    /// Who is doing what, for VoiceOver: `Claude Code · Editing app.rs:42`.
    public var summary: String
    /// What the agent drives; nil for quieter activity (the dot).
    public var drive: Drive?

    public init(colorKey: String, summary: String, drive: Drive? = nil) {
        self.colorKey = colorKey
        self.summary = summary
        self.drive = drive
    }
}
