import Foundation

/// Settings under the dotted-id prefix `statusBar.*`.
///
/// The status bar is one line along the bottom of every window, filled by a
/// program the user picks. cmux runs ``command`` once for the whole app and
/// shows the last line it printed; an empty command hides the bar.
public struct StatusBarCatalogSection: SettingCatalogSection {
    /// Shell command whose output fills the bar, run with `/bin/sh -c`.
    public let command = DefaultsKey<String>(
        id: "statusBar.command",
        defaultValue: "",
        userDefaultsKey: "statusBar.command"
    )

    /// Font size of the bar's text, in points.
    public let fontSize = DefaultsKey<Double>(
        id: "statusBar.fontSize",
        defaultValue: 11,
        userDefaultsKey: "statusBar.fontSize"
    )

    /// Where the line sits when it is narrower than the window.
    public let alignment = DefaultsKey<SessionContentAlignment>(
        id: "statusBar.alignment",
        defaultValue: .left,
        userDefaultsKey: "statusBar.alignment"
    )

    /// Font sizes `statusBar.fontSize` accepts.
    public static let fontSizeRange: ClosedRange<Double> = 8...20

    /// Creates the status bar settings section with its default keys.
    public init() {}
}
