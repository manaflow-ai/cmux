import Foundation

/// The localized format strings a ``CommandPaletteSettingToggleDescriptor`` uses
/// to render its command title and subtitle, resolved app-side and handed across
/// this seam.
///
/// `String(localized:)` resolves against the *calling* bundle. Resolving these
/// formats inside this package would bind to the package bundle, which does not
/// carry the app's `Localizable.xcstrings` keys, silently dropping every
/// non-English (e.g. Japanese) translation. So the app resolves each format once
/// — preserving its existing key and default value — and passes the
/// already-resolved text to ``CommandPaletteSettingToggleDescriptor/commandTitle(strings:defaults:)``
/// and ``CommandPaletteSettingToggleDescriptor/commandSubtitle(strings:defaults:)``,
/// which interpolate the per-descriptor title/section text into them.
public struct CommandPaletteSettingToggleStrings: Sendable, Equatable {
    /// Format for the "Disable %@" title shown when the setting is currently on.
    public let disableTitleFormat: String
    /// Format for the "Enable %@" title shown when the setting is currently off.
    public let enableTitleFormat: String
    /// The "On" state word used in the subtitle when the setting is on.
    public let onState: String
    /// The "Off" state word used in the subtitle when the setting is off.
    public let offState: String
    /// Format for the "%@ • %@" subtitle (section title, then state word).
    public let subtitleFormat: String

    /// Creates the toggle-command string bundle.
    public init(
        disableTitleFormat: String,
        enableTitleFormat: String,
        onState: String,
        offState: String,
        subtitleFormat: String
    ) {
        self.disableTitleFormat = disableTitleFormat
        self.enableTitleFormat = enableTitleFormat
        self.onState = onState
        self.offState = offState
        self.subtitleFormat = subtitleFormat
    }
}
