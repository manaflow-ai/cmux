import CmuxFoundation
import Foundation
import Observation

/// Drives the Settings terminal theme gallery.
///
/// Picking a card writes the managed `# cmux themes` block through the same
/// ``CmuxManagedThemeConfigFile`` writer `cmux themes` uses, then asks the host
/// to reload so terminals preview it live. The first pick snapshots the config
/// file; ``revert()`` puts that snapshot back.
@MainActor
@Observable
final class TerminalThemeGalleryModel {
    /// The appearance whose theme a pick replaces.
    enum Slot: Hashable, CaseIterable, Sendable {
        case light
        case dark
    }

    /// One theme file with the colors its card renders.
    struct Theme: Identifiable, Equatable, Sendable {
        let name: String
        let colors: GhosttyThemeColors
        var id: String { name }
    }

    /// The cards shown for a query, and whether more themes matched than fit.
    struct Results: Equatable {
        let themes: [Theme]
        let isTruncated: Bool
    }

    private struct Snapshot {
        let contents: String?
        let selection: CmuxTerminalThemePair
    }

    /// Shown when the search field is empty: light and dark variants of
    /// popular families, so either slot has six good starting points.
    nonisolated static let curatedThemeNames = [
        "Catppuccin Latte", "Catppuccin Mocha",
        "GitHub Light Default", "GitHub Dark Default",
        "Rose Pine Dawn", "Rose Pine",
        "Gruvbox Light", "Gruvbox Dark",
        "TokyoNight Day", "TokyoNight",
        "Nord Light", "Nord",
    ]

    /// Caps search results so a one-letter query does not build hundreds of cards.
    nonisolated static let searchResultLimit = 48

    @ObservationIgnored private let context: TerminalThemeGalleryContext
    @ObservationIgnored private let reload: @MainActor (TerminalThemeReloadPhase) -> Void
    @ObservationIgnored private var snapshot: Snapshot?

    private(set) var themes: [Theme] = []
    private(set) var isLoaded = false
    private(set) var selection: CmuxTerminalThemePair
    private(set) var hasPendingChange = false
    private(set) var writeFailed = false
    var slot: Slot
    var query = ""

    init(
        context: TerminalThemeGalleryContext,
        reload: @escaping @MainActor (TerminalThemeReloadPhase) -> Void
    ) {
        self.context = context
        self.reload = reload
        selection = CmuxManagedThemeBlock.themePair(fromRawValue: context.currentThemeValue)
        slot = context.prefersDarkAppearance ? .dark : .light
    }

    /// Reads and parses every theme file off the main actor, once.
    func load() async {
        guard !isLoaded else { return }
        let directories = context.themeDirectories
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.loadThemes(in: directories)
        }.value
        themes = loaded
        isLoaded = true
    }

    /// The cards for the current query and slot.
    var results: Results {
        Self.results(in: themes, query: query, slot: slot)
    }

    /// The theme in effect for `slot`, or `nil` when it uses Ghostty's defaults.
    func selectedName(for slot: Slot) -> String? {
        switch slot {
        case .light: selection.light
        case .dark: selection.dark
        }
    }

    /// Uses `name` for the current slot and live-previews it.
    ///
    /// Ghostty needs both sides of a conditional theme, so an unset opposite
    /// side takes the same theme.
    func select(_ name: String) {
        var next = selection
        switch slot {
        case .light:
            next.light = name
            if next.dark == nil { next.dark = name }
        case .dark:
            next.dark = name
            if next.light == nil { next.light = name }
        }
        guard next != selection,
              let rawValue = CmuxManagedThemeBlock.encodedThemeValue(light: next.light, dark: next.dark) else {
            return
        }
        do {
            if snapshot == nil {
                snapshot = Snapshot(contents: try context.configFile.readContents(), selection: selection)
            }
            try context.configFile.write(rawThemeValue: rawValue)
        } catch {
            writeFailed = true
            return
        }
        selection = next
        hasPendingChange = true
        writeFailed = false
        reload(.preview)
    }

    /// Restores the config file as it was before the first pick.
    func revert() {
        guard let snapshot else { return }
        do {
            try context.configFile.restore(snapshot.contents)
        } catch {
            writeFailed = true
            return
        }
        selection = snapshot.selection
        self.snapshot = nil
        hasPendingChange = false
        writeFailed = false
        reload(.final)
    }

    nonisolated static func loadThemes(in directories: [URL]) -> [Theme] {
        GhosttyThemeCatalog.entries(in: directories).compactMap { entry in
            guard let contents = try? String(contentsOf: entry.url, encoding: .utf8) else { return nil }
            return Theme(name: entry.name, colors: GhosttyThemeColors(parsing: contents))
        }
    }

    /// With an empty query, the curated themes that exist, those matching the
    /// slot's appearance first. Otherwise, every name containing the query.
    nonisolated static func results(in themes: [Theme], query: String, slot: Slot) -> Results {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty else {
            let matches = themes.filter { $0.name.localizedCaseInsensitiveContains(query) }
            return Results(
                themes: Array(matches.prefix(searchResultLimit)),
                isTruncated: matches.count > searchResultLimit
            )
        }

        var byName: [String: Theme] = [:]
        for theme in themes {
            byName[theme.name.lowercased()] = theme
        }
        let curated = curatedThemeNames.compactMap { byName[$0.lowercased()] }
        let wantsDark = slot == .dark
        let matching = curated.filter { ($0.colors.isDark ?? wantsDark) == wantsDark }
        let others = curated.filter { ($0.colors.isDark ?? wantsDark) != wantsDark }
        return Results(themes: matching + others, isTruncated: false)
    }
}
