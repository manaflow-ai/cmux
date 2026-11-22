public import CmuxNextSettings
import CmuxNextDesign
public import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// The Make cmux Yours step's source over the app's settings owner (cmux#48416). Each pick is the
/// person's own write, made at once so the window behind shows it:
/// - how they work: `tabs.newTabTemplate` `terminal` for terminal-first (a person's Cmd-T then opens a
///   terminal, cmux-window-rules `tabs::new_tab_kind`), removed for GUI-first (the New Tab page);
/// - density: through the App's `appearance.density.set` (`setDensity`), which also applies the tokens;
/// - background: `appearance.background`, removed for none;
/// - its Opacity and Material: `appearance.backgroundOpacity` and `appearance.backgroundBlur`, the
///   rows Settings > Appearance draws under its background picker, removed when put back unset;
/// - Text Size, Theme, Accent and Window Style: `appearance.metrics.chromeFontSize`, `appearance.theme`,
///   `appearance.accent` and `appearance.chromeStyle`, Settings > Appearance's own keys, removed when unset.
@MainActor
public final class FirstRunChoicesSettingsSource: FirstRunChoicesSource {
    /// The built-in backgrounds the step offers after None (cmux#49636): Shuffle Paintings, then
    /// well-known, calm works that read well behind text. Each has a bundled thumbnail; a work whose full
    /// image is not in the app downloads on its first pick. Settings > Appearance has the rest.
    nonisolated static let offered = [
        shuffleID,
        "van-gogh-starry-night", "hokusai-great-wave", "friedrich-wanderer", "dahl-dresden-moonlight", "monet-water-lilies-setting-sun",
        "hiroshige-kanbara-snow", "van-gogh-almond-blossom", "bruegel-hunters-snow", "roerich-himalayas", "vermeer-pearl-earring",
    ]
    /// Shuffle Paintings' `appearance.background` value: a new painting each day.
    nonisolated static let shuffleID = "daily"
    /// The work Shuffle Paintings' tile shows.
    nonisolated static let shufflePreview = "monet-impression-sunrise"

    /// The terminal themes the step offers after the Ghostty config's (cmux#49636): well-known families
    /// as light/dark pairs that follow macOS's appearance, as Settings' Theme row writes them
    /// (`light:<theme>,dark:<theme>`); a family with no light side is its dark theme alone. Every name
    /// is one of Ghostty's bundled themes. Settings > Appearance has all of them.
    nonisolated static let offeredThemes: [(name: String, light: String?, dark: String)] = [
        ("Catppuccin", "Catppuccin Latte", "Catppuccin Mocha"),
        ("Rosé Pine", "Rose Pine Dawn", "Rose Pine"),
        ("Tokyo Night", "TokyoNight Day", "TokyoNight Night"),
        ("Gruvbox", "Gruvbox Light", "Gruvbox Dark"),
        ("Nord", "Nord Light", "Nord"),
        ("GitHub", "GitHub Light Default", "GitHub Dark Default"),
        ("Everforest", "Everforest Light Med", "Everforest Dark Med"),
        ("One Half", "One Half Light", "One Half Dark"),
        ("Kanagawa", "Kanagawa Lotus", "Kanagawa Wave"),
        ("Dracula", nil, "Dracula"),
    ]

    /// A theme's `appearance.theme` value.
    nonisolated static func themeSpec(light: String?, dark: String) -> String {
        light.map { "light:\($0),dark:\(dark)" } ?? dark
    }

    /// The way to work the person picked on the step, if they changed it: read before its settings write lands,
    /// so the first chat (none for terminal-first) does not race a Return pressed right after the pick.
    public private(set) var pickedWorkStyle: WorkStyle?

    private let settings: @MainActor () -> SettingsController?
    private let setDensity: @MainActor (String) -> Void
    private let windowOpacity: @MainActor () -> Double?
    private let themeSwatch: @MainActor (String) -> [String]
    private let accentSwatch: @MainActor (String) -> String?
    private let log = Logger(subsystem: "com.cmuxterm.app.next", category: "onboarding")
    /// The writes not yet sent, oldest first, one per setting: a slider's steps coalesce into its last.
    private var pending: [(path: [String], value: JSONValue?)] = []
    private var writer: Task<Void, Never>?

    /// `settings` is the app's settings owner (nil before it started); `setDensity` runs the density
    /// action with a preset id (`compact`, `cozy`, `comfortable`); `windowOpacity` reads the opacity
    /// the window shows now (Settings' unset slider's reading); `themeSwatch` is a Ghostty theme's swatch
    /// strip as `#RRGGBB` (empty before the theme files are read); `accentSwatch` is the color an Accent
    /// gives the window's theme (`#RRGGBB`; nil for Art Color, which takes the art's hue).
    public init(settings: @escaping @MainActor () -> SettingsController?, setDensity: @escaping @MainActor (String) -> Void,
                windowOpacity: @escaping @MainActor () -> Double? = { nil },
                themeSwatch: @escaping @MainActor (String) -> [String] = { _ in [] },
                accentSwatch: @escaping @MainActor (String) -> String? = { _ in nil }) {
        self.settings = settings
        self.setDensity = setDensity
        self.windowOpacity = windowOpacity
        self.themeSwatch = themeSwatch
        self.accentSwatch = accentSwatch
    }

    public func accentSwatch(_ accent: String) -> String? { accentSwatch(accent) }

    public func currentChoices() -> FirstRunChoices {
        guard let snapshot = settings()?.snapshot else { return .recommended }
        let template = snapshot.root.value(at: ["tabs", "newTabTemplate"])?.stringValue
        let root = snapshot.root
        let background = root.value(at: ["appearance", "background"])?.stringValue
        return FirstRunChoices(workStyle: template == "terminal" ? .terminal : .gui,
                               density: Self.density(snapshot.density),
                               background: background == "none" ? nil : background,
                               opacity: snapshot.windowBackground.opacity,
                               material: snapshot.windowBackground.material.flatMap { FirstRunMaterial(rawValue: $0.rawValue) },
                               textSize: root.value(at: Self.textSizePath)?.doubleValue,
                               theme: root.value(at: Self.themePath)?.stringValue,
                               accent: root.value(at: Self.accentPath)?.stringValue,
                               windowStyle: root.value(at: Self.windowStylePath)?.stringValue)
    }

    /// Settings > Appearance's keys for the step's look rows.
    nonisolated static let textSizePath = ["appearance", "metrics", "chromeFontSize"]
    nonisolated static let themePath = ["appearance", "theme"]
    nonisolated static let accentPath = ["appearance", "accent"]
    nonisolated static let windowStylePath = ["appearance", "chromeStyle"]

    public func themes() -> [FirstRunTheme] {
        Self.offeredThemes.map { theme in
            let dark = themeSwatch(theme.dark)
            return FirstRunTheme(id: Self.themeSpec(light: theme.light, dark: theme.dark), name: theme.name,
                                 light: theme.light.map(themeSwatch) ?? dark, dark: dark)
        }
    }

    public func textSize(density: String) -> Double? {
        DensityPreset(rawValue: density).map { Double($0.tokens.bodySize) }
    }

    /// The density setting as a preset id: unset is Settings' Default.
    static func density(_ value: String?) -> String {
        value.flatMap(DensityPreset.init(rawValue:))?.rawValue ?? value ?? FirstRunChoices.defaultDensity
    }

    /// Every built-in density, in Settings' order and by Settings' names.
    public func densities() -> [FirstRunDensity] { Self.densities }

    static var densities: [FirstRunDensity] {
        DensityPreset.allCases.map { FirstRunDensity(id: $0.rawValue, name: DensityNames().name($0.tokens)) }
    }

    public func shownOpacity() -> Double? { windowOpacity() }

    public func backgrounds() async -> [FirstRunBackground] {
        // Shuffle Paintings is a mode, not a work: no name (the page says it in its language), a painting's preview.
        let rows: [(id: String, name: String, url: URL?)] = Self.offered.compactMap { id in
            if id == Self.shuffleID { return (id, "", BackdropSelection(id: Self.shufflePreview)?.thumbnailURL) }
            guard let selection = BackdropSelection(id: id) else { return nil }
            return (id, selection.title, selection.thumbnailURL)
        }
        let previews = await Self.previews(rows.map(\.url))
        return zip(rows, previews).map { FirstRunBackground(id: $0.id, name: $0.name, preview: $1) }
    }

    public func apply(_ new: FirstRunChoices, from old: FirstRunChoices) {
        if new.workStyle != old.workStyle { pickedWorkStyle = new.workStyle }
        if new.density != old.density { setDensity(new.density) }
        var writes: [([String], JSONValue?)] = []
        if new.workStyle != old.workStyle { writes.append((["tabs", "newTabTemplate"], new.workStyle == .terminal ? .string("terminal") : nil)) }
        if new.background != old.background { writes.append((["appearance", "background"], new.background.map(JSONValue.string))) }
        if new.opacity != old.opacity { writes.append((WindowBackgroundSetting.opacityPath, new.opacity.map(JSONValue.number))) }
        if new.material != old.material { writes.append((WindowBackgroundSetting.materialPath, new.material.map { .string($0.rawValue) })) }
        if new.textSize != old.textSize { writes.append((Self.textSizePath, new.textSize.map(JSONValue.number))) }
        if new.theme != old.theme { writes.append((Self.themePath, new.theme.map(JSONValue.string))) }
        if new.accent != old.accent { writes.append((Self.accentPath, new.accent.map(JSONValue.string))) }
        if new.windowStyle != old.windowStyle { writes.append((Self.windowStylePath, new.windowStyle.map(JSONValue.string))) }
        for (path, value) in writes {
            if let index = pending.firstIndex(where: { $0.path == path }) { pending.remove(at: index) }
            pending.append((path, value))
        }
        drain()
    }

    /// Sends the pending writes one at a time, in the order they were picked: two picks in a row
    /// (or a dragged slider) never land out of order.
    private func drain() {
        guard writer == nil, !pending.isEmpty else { return }
        // task-owner: the one writer of the step's picks; it ends when nothing is pending.
        writer = Task { [weak self] in
            while let self, !pending.isEmpty {
                let (path, value) = pending.removeFirst()
                guard let settings = settings() else {
                    log.error("first-run choice \(path.joined(separator: "."), privacy: .public) not saved: settings are not started")
                    continue
                }
                do {
                    try await settings.setSetting(at: path, to: value, by: .user)
                } catch {
                    log.error("first-run choice \(path.joined(separator: "."), privacy: .public) refused: \(String(describing: error), privacy: .public)")
                }
            }
            self?.writer = nil
        }
    }

    /// Small `data:` PNGs of `urls`, decoded off the main actor (nil for a missing file).
    @concurrent nonisolated static func previews(_ urls: [URL?]) async -> [String?] {
        urls.map { url in url.flatMap(preview(at:)) }
    }

    /// A PNG at most 160 pixels wide of the image at `url`, as a `data:` URL.
    nonisolated static func preview(at url: URL) -> String? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }
}
