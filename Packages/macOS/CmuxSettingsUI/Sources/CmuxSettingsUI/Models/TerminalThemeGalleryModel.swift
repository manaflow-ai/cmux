import CmuxFoundation
import Foundation
import Observation
import SwiftUI

/// Drives the Settings terminal theme gallery.
///
/// Picking a card writes the managed `# cmux themes` block through the same
/// ``CmuxManagedThemeConfigFile`` writer `cmux themes` uses, then asks the host
/// to reload so terminals preview it live. The first pick remembers the
/// block's previous theme value; ``revert()`` writes only that value back, so
/// other edits to the file made in the meantime survive.
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
        /// Card colors resolved once at load, so scrolling the gallery never
        /// converts hex components while cards come into view.
        let preview: PreviewColors
        var id: String { name }

        init(name: String, colors: GhosttyThemeColors) {
            self.name = name
            self.colors = colors
            self.preview = PreviewColors(colors)
        }
    }

    /// The SwiftUI colors a theme card draws.
    struct PreviewColors: Equatable, Sendable {
        let background: Color?
        let foreground: Color?
        let cursor: Color?
        let palette: [Color?]

        init(_ colors: GhosttyThemeColors) {
            func color(_ rgb: GhosttyThemeRGB?) -> Color? {
                rgb.map { Color(.sRGB, red: Double($0.red) / 255, green: Double($0.green) / 255, blue: Double($0.blue) / 255, opacity: 1) }
            }
            background = color(colors.background)
            foreground = color(colors.foreground)
            cursor = color(colors.cursor)
            palette = colors.palette.map(color)
        }
    }

    /// The cards shown for a query, split by appearance: themes that suit
    /// the slot being edited first, then the rest.
    struct Results: Equatable {
        /// Themes whose background matches the slot (unknown counts as matching).
        let matchingSlot: [Theme]
        /// Themes built for the other appearance.
        let otherAppearance: [Theme]

        /// Every card, in display order.
        var themes: [Theme] { matchingSlot + otherAppearance }
    }

    /// The managed block's theme before the first pick (`nil`: no block).
    private struct Snapshot {
        let managedThemeValue: String?
    }

    @ObservationIgnored private let context: TerminalThemeGalleryContext
    @ObservationIgnored private let reload: @MainActor (TerminalThemeReloadPhase) -> Void
    @ObservationIgnored private var snapshot: Snapshot?
    @ObservationIgnored private let block = CmuxManagedThemeBlock()

    private(set) var themes: [Theme] = []
    private(set) var isLoaded = false
    private(set) var selection: CmuxTerminalThemePair
    private(set) var hasPendingChange = false
    private(set) var writeFailed = false
    var slot: Slot
    var query = ""
    /// Whether light and dark appearances get separate themes. Off, a pick
    /// sets both, so it always applies to the appearance in use. Starts on
    /// only when the config already holds two different themes.
    private(set) var separatesAppearances: Bool
    /// The appearance whose theme the terminal shows now.
    let slotInUse: Slot

    init(
        context: TerminalThemeGalleryContext,
        reload: @escaping @MainActor (TerminalThemeReloadPhase) -> Void
    ) {
        self.context = context
        self.reload = reload
        let initialSelection = CmuxManagedThemeBlock().themePair(fromRawValue: context.readCurrentThemeValue())
        let initialSlot: Slot = context.prefersDarkAppearance ? .dark : .light
        selection = initialSelection
        slot = initialSlot
        slotInUse = initialSlot
        separatesAppearances = Self.holdsSeparateThemes(initialSelection)
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

    /// Re-reads the theme in effect, picking up changes made outside Settings.
    func refreshSelection() {
        selection = currentPair()
    }

    /// Uses `name` for both appearances, or only for the current slot when
    /// ``separatesAppearances`` is on, and live-previews it.
    ///
    /// The other side comes from the config as it is now, not as it was when
    /// Settings opened. Ghostty needs both sides of a conditional theme, so an
    /// unset opposite side takes the same theme.
    func select(_ name: String) {
        let current: CmuxTerminalThemePair
        let managedValue: String?
        do {
            managedValue = try context.configFile.managedThemeValue()
            current = managedValue.map { block.themePair(fromRawValue: $0) } ?? currentPair()
        } catch {
            writeFailed = true
            return
        }
        selection = current
        var next = current
        switch separatesAppearances ? slot : nil {
        case nil:
            next.light = name
            next.dark = name
        case .light?:
            next.light = name
            if next.dark == nil { next.dark = name }
        case .dark?:
            next.dark = name
            if next.light == nil { next.light = name }
        }
        guard next != current,
              let rawValue = block.encodedThemeValue(light: next.light, dark: next.dark) else {
            return
        }
        do {
            try context.configFile.write(rawThemeValue: rawValue)
        } catch {
            writeFailed = true
            return
        }
        if snapshot == nil {
            snapshot = Snapshot(managedThemeValue: managedValue)
        }
        selection = next
        hasPendingChange = true
        writeFailed = false
        reload(.preview)
    }

    /// Turns separate light and dark themes on or off. Turning them off gives
    /// both appearances the theme in use now, so what the terminal shows does
    /// not change; turning them on edits the appearance in use first.
    func setSeparatesAppearances(_ separates: Bool) {
        guard separates != separatesAppearances else { return }
        separatesAppearances = separates
        slot = slotInUse
        guard !separates, let inUse = selectedName(for: slotInUse) else { return }
        let wasSeparate = selection.light != selection.dark
        guard wasSeparate else { return }
        select(inUse)
    }

    /// Whether a pair names two different themes.
    nonisolated static func holdsSeparateThemes(_ pair: CmuxTerminalThemePair) -> Bool {
        guard let light = pair.light, let dark = pair.dark else { return false }
        return light.caseInsensitiveCompare(dark) != .orderedSame
    }

    /// Puts the managed block's theme back as it was before the first pick,
    /// removing the block if there was none. The rest of the file is untouched.
    func revert() {
        guard let snapshot else { return }
        do {
            try context.configFile.setManagedThemeValue(snapshot.managedThemeValue)
        } catch {
            writeFailed = true
            return
        }
        self.snapshot = nil
        selection = currentPair()
        hasPendingChange = false
        writeFailed = false
        reload(.final)
    }

    /// The effective theme: the managed block when present, otherwise
    /// whatever the loaded Ghostty config sets.
    private func currentPair() -> CmuxTerminalThemePair {
        if let managedValue = try? context.configFile.managedThemeValue() {
            return block.themePair(fromRawValue: managedValue)
        }
        return block.themePair(fromRawValue: context.readCurrentThemeValue())
    }

    nonisolated static func loadThemes(in directories: [URL]) -> [Theme] {
        GhosttyThemeCatalog(directories: directories).entries().compactMap { entry in
            guard let contents = try? String(contentsOf: entry.url, encoding: .utf8) else { return nil }
            return Theme(name: entry.name, colors: GhosttyThemeColors(parsing: contents))
        }
    }

    /// Every theme whose name contains the query (all themes when the query
    /// is empty), in catalog order, those matching the slot's appearance first.
    nonisolated static func results(in themes: [Theme], query: String, slot: Slot) -> Results {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? themes : themes.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let wantsDark = slot == .dark
        var matchingSlot: [Theme] = []
        var otherAppearance: [Theme] = []
        for theme in matches {
            if (theme.colors.isDark ?? wantsDark) == wantsDark {
                matchingSlot.append(theme)
            } else {
                otherAppearance.append(theme)
            }
        }
        return Results(matchingSlot: matchingSlot, otherAppearance: otherAppearance)
    }
}
