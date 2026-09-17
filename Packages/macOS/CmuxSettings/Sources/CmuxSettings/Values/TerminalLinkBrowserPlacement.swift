import Foundation

/// Controls where a terminal link opens when it uses the embedded browser.
public enum TerminalLinkBrowserPlacement: String, CaseIterable, Hashable, Identifiable, Sendable, SettingCodable {
    /// Reuses the nearest right-side browser pane, creating a split when needed.
    case reuseOrSplit

    /// Opens a new browser surface in the source terminal's pane.
    case samePane

    /// Always creates a new browser split from the source terminal.
    case split

    /// Stable identifier matching the value written to configuration.
    public var id: String { rawValue }

    /// Localized name shown in Browser settings.
    public var displayName: String {
        switch self {
        case .reuseOrSplit:
            return String(
                localized: "settings.browser.terminalLinkPlacement.reuseOrSplit",
                defaultValue: "Reuse or Split"
            )
        case .samePane:
            return String(
                localized: "settings.browser.terminalLinkPlacement.samePane",
                defaultValue: "Same Pane"
            )
        case .split:
            return String(
                localized: "settings.browser.terminalLinkPlacement.split",
                defaultValue: "New Split"
            )
        }
    }

    /// Localized explanation of the placement strategy shown below its picker.
    public var settingsSubtitle: String {
        switch self {
        case .reuseOrSplit:
            return String(
                localized: "settings.browser.terminalLinkPlacement.subtitle.reuseOrSplit",
                defaultValue: "Open terminal links in a nearby browser pane, or create a split when none is available."
            )
        case .samePane:
            return String(
                localized: "settings.browser.terminalLinkPlacement.subtitle.samePane",
                defaultValue: "Open terminal links as browser tabs in the pane where the link was clicked."
            )
        case .split:
            return String(
                localized: "settings.browser.terminalLinkPlacement.subtitle.split",
                defaultValue: "Always open terminal links in a new browser split."
            )
        }
    }
}
