import CmuxSettings
import Foundation

@MainActor
extension TerminalSection {
    static func sessionContentWidthSubtitle(enabled: Bool) -> String {
        if enabled {
            return String(
                localized: "settings.terminal.sessionContentWidth.subtitleOn",
                defaultValue: "Terminal and agent chat content wraps within this width. Narrow panes still use all available space."
            )
        }
        return String(
            localized: "settings.terminal.sessionContentWidth.subtitleOff",
            defaultValue: "Terminal and agent chat content uses the full pane width."
        )
    }

    static func sessionContentAlignmentTitle(_ alignment: SessionContentAlignment) -> String {
        switch alignment {
        case .left:
            return String(localized: "settings.terminal.sessionContentAlignment.left", defaultValue: "Left")
        case .center:
            return String(localized: "settings.terminal.sessionContentAlignment.center", defaultValue: "Center")
        case .right:
            return String(localized: "settings.terminal.sessionContentAlignment.right", defaultValue: "Right")
        }
    }
}
