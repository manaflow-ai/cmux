public import Foundation
public import Observation
import CmuxNextCompat
import CmuxNextDesignTokens

/// The All Themes playground's state (Debug menu > All Themes Playground): every theme file in
/// the folders it is given, each as the App Theme with its ``ThemeElementAudit``, and the search
/// and the "failures only" filter.
@MainActor @Observable public final class AllThemesPlaygroundModel {
    /// Every theme, failing ones first, then by name.
    public private(set) var entries: [AllThemesPlaygroundEntry] = []
    /// Shows only themes whose name contains this text (case-insensitive); empty shows all.
    public var query = ""
    /// Shows only themes with a failing sample.
    public var failuresOnly = false

    /// The themes the filter shows.
    public var shown: [AllThemesPlaygroundEntry] {
        entries.filter { entry in
            (!failuresOnly || !entry.failures.isEmpty)
                && (query.isEmpty || entry.name.localizedCaseInsensitiveContains(query))
        }
    }

    /// The number of themes with a failing sample.
    public var failingCount: Int { entries.count { !$0.failures.isEmpty } }

    /// An empty playground; ``load(folders:)`` reads the themes.
    public init() {}

    /// Reads every theme file in `folders` off the main thread (later folders win on a name), then
    /// audits each on the main actor, where its theme scope lives.
    /// - Parameter folders: Theme folders, such as the app's `Resources/ghostty/themes`.
    public func load(folders: [URL]) async {
        let colors = await Self.read(folders)
        entries = colors.compactMap(Self.entry)
            .sorted { ($0.failures.isEmpty ? 1 : 0, $0.name) < ($1.failures.isEmpty ? 1 : 0, $1.name) }
    }

    /// The colors of every theme file in `folders`, read on the cooperative pool.
    @concurrent private nonisolated static func read(_ folders: [URL]) async -> [ThemeFileColors] {
        var files: [String: URL] = [:]
        for folder in folders {
            for name in (try? FileManager.checked.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(".") {
                files[name] = folder.appending(path: name)
            }
        }
        return files.compactMap { name, url in
            (try? String(blockingContentsOf: url, encoding: .utf8)).flatMap { ThemeFileColors(name: name, themeFile: $0) }
        }
    }

    private static func entry(_ colors: ThemeFileColors) -> AllThemesPlaygroundEntry? {
        let name = colors.name
        guard let spec = ThemeSpec("All Themes \(name)") else { return nil }
        let defaults = ThemeInput.ghosttyDefault.palette
        var input = ThemeInput(background: colors.background, foreground: colors.foreground,
                               palette: colors.palette.enumerated().map { $0.element ?? defaults[$0.offset] },
                               selectionBackground: colors.selectionBackground,
                               selectionForeground: colors.selectionForeground, cursor: colors.cursorColor)
        input.accentColor = colors.accent
        let scope = ThemeScope(level: .workspace)
        scope.setOverride(spec, input: input, animated: false)
        return AllThemesPlaygroundEntry(name: name, isDark: scope.tokens.isDark, background: colors.background,
                                        foreground: colors.foreground, samples: ThemeElementAudit(scope: scope).samples)
    }
}
