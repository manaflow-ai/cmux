import CmuxFoundation
import Foundation

/// What the Settings terminal theme gallery needs from the host: where themes
/// live, which config file holds the managed `# cmux themes` block, and the
/// theme currently in effect.
public struct TerminalThemeGalleryContext: Sendable {
    /// The cmux Ghostty config file the gallery writes, shared with `cmux themes`.
    public let configFile: CmuxManagedThemeConfigFile
    /// Directories searched for theme files. Earlier directories win on a name clash.
    public let themeDirectories: [URL]
    /// Reads the last `theme = ...` value across the loaded Ghostty config
    /// files. Called again before each pick so a change made meanwhile (for
    /// example by `cmux themes`) is not overwritten with a stale value.
    public let readCurrentThemeValue: @MainActor @Sendable () -> String?
    /// Whether the app currently renders in dark appearance.
    public let prefersDarkAppearance: Bool

    /// Creates a context.
    /// - Parameters:
    ///   - configFile: The managed config file both writers share.
    ///   - themeDirectories: Usually ``GhosttyThemeDirectories/urls``.
    ///   - readCurrentThemeValue: Returns the effective `theme` value now.
    ///   - prefersDarkAppearance: Picks the slot the gallery opens on.
    public init(
        configFile: CmuxManagedThemeConfigFile,
        themeDirectories: [URL],
        readCurrentThemeValue: @escaping @MainActor @Sendable () -> String?,
        prefersDarkAppearance: Bool
    ) {
        self.configFile = configFile
        self.themeDirectories = themeDirectories
        self.readCurrentThemeValue = readCurrentThemeValue
        self.prefersDarkAppearance = prefersDarkAppearance
    }
}

/// How the host should reload terminals after the gallery rewrote the block.
public enum TerminalThemeReloadPhase: Sendable {
    /// A card was picked; rapid picks can coalesce into one reload.
    case preview
    /// The previous theme was restored; reload now.
    case final
}
