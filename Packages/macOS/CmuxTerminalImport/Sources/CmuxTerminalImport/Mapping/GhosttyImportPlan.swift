/// Everything `cmux import <source>` will write, computed without touching disk.
///
/// The CLI prints the plan as a diff, and writes it only without `--dry-run`.
public struct GhosttyImportPlan: Equatable, Sendable {
    /// Where the settings came from.
    public var source: TerminalImportSource
    /// Theme files to create or replace in cmux's themes directory.
    public var themeFiles: [GhosttyThemeFile] = []
    /// The `theme` value to select the generated theme(s), or `nil` when the source had no colors.
    public var themeValue: String?
    /// Non-theme settings for cmux's Ghostty config, in write order.
    public var settings: [GhosttyConfigSetting] = []
    /// Human-readable notes: settings not imported, approximations, and why.
    public var notes: [String] = []

    /// Creates an empty plan for a source.
    public init(source: TerminalImportSource) {
        self.source = source
    }

    /// Whether the plan would write nothing.
    public var isEmpty: Bool {
        themeFiles.isEmpty && themeValue == nil && settings.isEmpty
    }
}
