public import CmuxTheme
public import Foundation
import Observation
#if os(iOS)
public import UIKit
#endif

/// The Mac's theme and wallpaper as its host serves them on the `appearance` service
/// (`cmux-mobile-host` `appearance.rs`, PROTOCOL.md): the colors the Mac's chrome derives from and
/// the picture behind its sidebar, by content id (ask-87d30da8e5).
public struct CmuxMobileMacAppearance: Codable, Equatable, Sendable {
    public struct Theme: Codable, Equatable, Sendable {
        public var background: String
        public var foreground: String
        public var palette: [String]
        public var selectionBackground: String?
        public var selectionForeground: String?
        public var cursor: String?
        /// `appearance.accent` on the Mac (`art`: the art's hue, sent as ``accentColor``).
        public var accent: String
        public var accentColor: String?
        public var backgroundOpacity: Double

        public init(background: String, foreground: String, palette: [String], selectionBackground: String? = nil,
                    selectionForeground: String? = nil, cursor: String? = nil, accent: String = "neutral",
                    accentColor: String? = nil, backgroundOpacity: Double = 1) {
            self.background = background
            self.foreground = foreground
            self.palette = palette
            self.selectionBackground = selectionBackground
            self.selectionForeground = selectionForeground
            self.cursor = cursor
            self.accent = accent
            self.accentColor = accentColor
            self.backgroundOpacity = backgroundOpacity
        }
    }

    public struct Wallpaper: Codable, Equatable, Sendable {
        /// SHA-256 of the picture, hex: the cache key.
        public var id: String
        public var bytes: Int
        /// The tint the Mac lays over the picture, 0...1.
        public var tintOpacity: Double

        public init(id: String, bytes: Int, tintOpacity: Double) {
            self.id = id
            self.bytes = bytes
            self.tintOpacity = tintOpacity
        }
    }

    public var theme: Theme
    public var wallpaper: Wallpaper?
    /// The Mac's terminal theme as Ghostty config lines (`appearance.terminal`): what its
    /// terminals show, apart from the chrome's colors above (which its app theme can replace).
    /// Nil from a Mac that predates it (``CmuxMobileTerminalTheme/init(appearance:)``).
    public var terminal: [String]?

    public init(theme: Theme, wallpaper: Wallpaper? = nil, terminal: [String]? = nil) {
        self.theme = theme
        self.wallpaper = wallpaper
        self.terminal = terminal
    }

    /// One `appearance` frame; nil for anything the phone cannot derive a palette from.
    public static func decode(_ data: Data) -> CmuxMobileMacAppearance? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let appearance = try? decoder.decode(Self.self, from: data), appearance.input != nil else { return nil }
        return appearance
    }

    /// The theme as the Mac's chrome reads it (`ThemeInput`). Opaque: nothing shows through
    /// the phone's window. Nil when a required color is malformed.
    public var input: ThemeInput? {
        guard let background = ThemeRGB(cssHex: theme.background), let foreground = ThemeRGB(cssHex: theme.foreground) else { return nil }
        let palette = theme.palette.compactMap(ThemeRGB.init(cssHex:))
        guard palette.count == theme.palette.count, palette.count == 8 || palette.count == 16 else { return nil }
        var input = ThemeInput(
            background: background, foreground: foreground, palette: palette,
            selectionBackground: theme.selectionBackground.flatMap(ThemeRGB.init(cssHex:)),
            selectionForeground: theme.selectionForeground.flatMap(ThemeRGB.init(cssHex:)),
            cursor: theme.cursor.flatMap(ThemeRGB.init(cssHex:)))
        input.accent = ThemeAccent(rawValue: theme.accent) ?? .neutral
        input.accentColor = theme.accentColor.flatMap(ThemeRGB.init(cssHex:))
        return input
    }
}

#if os(iOS)
/// The phone's color roles from the Mac's tokens (`ThemeTokens.derive`, the code the Mac's chrome
/// runs), so the phone draws the same palette for the same theme, with or without the Mac.
public struct CmuxMobileMacPalette: Equatable, Sendable {
    public var isDark: Bool
    public var bg: CmuxMobileRGBA
    public var surface: CmuxMobileRGBA
    public var surfaceRaised: CmuxMobileRGBA
    public var codeBg: CmuxMobileRGBA
    public var fill: CmuxMobileRGBA
    public var fillSelected: CmuxMobileRGBA
    public var fillPressed: CmuxMobileRGBA
    public var separator: CmuxMobileRGBA
    public var label: CmuxMobileRGBA
    public var label2: CmuxMobileRGBA
    public var label3: CmuxMobileRGBA
    public var success: CmuxMobileRGBA
    public var danger: CmuxMobileRGBA
    public var warning: CmuxMobileRGBA
    public var cardStroke: CmuxMobileRGBA
    public var shimmerBand: CmuxMobileRGBA
    /// The Mac's accent (its foreground without a hue) and its ink.
    public var accent: CmuxMobileRGBA
    public var onAccent: CmuxMobileRGBA
    /// The terminal's colors, `#rrggbb`: background, foreground and ANSI 0...15.
    public var terminalBackground: String
    public var terminalForeground: String
    public var terminalPalette: [String]

    public init(tokens: ThemeTokens, input: ThemeInput) {
        let fg = input.foreground
        let bg = input.background.withAlpha(1)
        func rgba(_ color: ThemeRGB) -> CmuxMobileRGBA {
            CmuxMobileRGBA(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        }
        func opaque(_ color: ThemeRGB) -> CmuxMobileRGBA { rgba(color.composited(over: bg).withAlpha(1)) }
        func hex(_ color: ThemeRGB) -> String {
            String(format: "#%02x%02x%02x", Int((color.red * 255).rounded()), Int((color.green * 255).rounded()),
                   Int((color.blue * 255).rounded()))
        }
        isDark = tokens.isDark
        self.bg = rgba(bg)
        surface = opaque(tokens.elevatedBackground)
        surfaceRaised = rgba(tokens.elevatedBackground.withAlpha(1).mixed(toward: fg, tokens.isDark ? 0.07 : 0.04))
        codeBg = opaque(tokens.chromeBackground)
        fill = rgba(fg.withAlpha(tokens.isDark ? 0.08 : 0.05))
        fillSelected = rgba(tokens.selectionFill)
        fillPressed = rgba(tokens.pressedFill)
        separator = opaque(tokens.separator)
        label = rgba(tokens.textPrimary)
        label2 = rgba(tokens.textSecondary)
        label3 = rgba(tokens.textTertiary)
        success = rgba(tokens.success)
        danger = rgba(tokens.danger)
        warning = rgba(tokens.attention)
        cardStroke = rgba(fg.withAlpha(tokens.isDark ? 0.10 : 0.08))
        shimmerBand = rgba(fg.withAlpha(tokens.isDark ? 0.06 : 0.04))
        accent = opaque(tokens.accent)
        onAccent = opaque(tokens.onAccent)
        terminalBackground = hex(bg)
        terminalForeground = hex(fg)
        terminalPalette = tokens.ansi.map(hex)
    }

    /// The palette of `appearance`, nil when it carries no usable theme.
    public init?(_ appearance: CmuxMobileMacAppearance) {
        guard let input = appearance.input else { return nil }
        self.init(tokens: ThemeTokens.derive(from: input), input: input)
    }

    /// Ghostty config lines that give the phone's terminals the Mac's colors.
    public var terminalConfigLines: [String] {
        ["background = \(terminalBackground)", "foreground = \(terminalForeground)"]
            + terminalPalette.enumerated().map { "palette = \($0.offset)=\($0.element)" }
    }
}

#endif

/// The last appearance a Mac sent, on disk: the phone paints it at launch before any link, and
/// keeps it while no Mac is reachable. One JSON file.
public struct CmuxMobileMacAppearanceCache: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// Application Support/cmux-mac-appearance.
    public static var standard: CmuxMobileMacAppearanceCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return CmuxMobileMacAppearanceCache(folder: base.appendingPathComponent("cmux-mac-appearance", isDirectory: true))
    }

    private var appearanceFile: URL { folder.appendingPathComponent("appearance.json") }

    public func load() -> CmuxMobileMacAppearance? {
        guard let data = try? Data(contentsOf: appearanceFile) else { return nil }
        return CmuxMobileMacAppearance.decode(data)
    }

    public func save(_ appearance: CmuxMobileMacAppearance) {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(appearance) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: appearanceFile, options: .atomic)
        // Wallpapers an earlier build kept here (the phone no longer shows the Mac's).
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("wallpaper-") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

#if os(iOS)
/// The Mac's theme on this phone: Settings > Appearance > Match Mac theme (on by default). While on,
/// the accent of an install that never picked one comes from the last theme a Mac sent
/// (``CmuxMobileMacPalette``), live while one is connected and from the cache otherwise. The app's
/// own backgrounds, text and fills stay the stock black and white chrome whatever the Mac shows, and
/// the Mac's wallpaper is not taken. SwiftUI views that read the accent in their body redraw when it
/// changes (Observation).
///
/// The palette is set at once on the main actor (a derivation, no disk). The JSON write runs off the
/// main actor, one after another in order.
@Observable
public final class CmuxMobileMacTheme: @unchecked Sendable {
    public static let shared = CmuxMobileMacTheme()
    /// A device preference (same prefix as `SettingsStore`): it stays across sign-outs.
    public static let settingKey = "cmuxMobile.settings.matchMacTheme"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cache: CmuxMobileMacAppearanceCache
    /// The last queued disk job: each one waits for it, so writes land in order.
    @ObservationIgnored private var diskTail: Task<Void, Never>?

    /// Whether the accent follows the Mac's theme.
    public var matchesMac: Bool {
        didSet { defaults.set(matchesMac, forKey: Self.settingKey) }
    }
    /// The last appearance a Mac sent (live or cached).
    public private(set) var appearance: CmuxMobileMacAppearance?
    /// Its palette, whatever ``matchesMac`` says (Settings previews it).
    public private(set) var macPalette: CmuxMobileMacPalette?

    /// Reads the cached appearance (one small JSON file: the first frame already has the accent).
    public init(defaults: UserDefaults = .standard, cache: CmuxMobileMacAppearanceCache = .standard) {
        self.defaults = defaults
        self.cache = cache
        matchesMac = defaults.object(forKey: Self.settingKey) as? Bool ?? true
        if let cached = cache.load() {
            appearance = cached
            macPalette = CmuxMobileMacPalette(cached)
        }
    }

    /// The palette the accent (and the terminal's launch colors) follow now: nil when off or no Mac
    /// ever sent one.
    public var palette: CmuxMobileMacPalette? { matchesMac ? macPalette : nil }

    /// A Mac's appearance, live: it wins over the cached one and is kept for the next launch. The
    /// palette changes at once; the write happens off the main actor (``settled()`` awaits it).
    @MainActor
    public func apply(_ appearance: CmuxMobileMacAppearance) {
        guard let palette = CmuxMobileMacPalette(appearance) else { return }
        if self.appearance != appearance { self.appearance = appearance }
        if macPalette != palette { macPalette = palette }
        let cache = cache
        enqueue { cache.save(appearance) }
    }

    /// Waits for the queued writes (tests, and anything that reads the cache next).
    public func settled() async {
        await diskTail?.value
    }

    /// Queues `job` off the main actor after every earlier one.
    @discardableResult
    private func enqueue<T: Sendable>(_ job: @escaping @Sendable () -> T) -> Task<T, Never> {
        let previous = diskTail
        let task = Task.detached(priority: .userInitiated) { () -> T in
            await previous?.value
            return job()
        }
        diskTail = Task { _ = await task.value }
        return task
    }

    /// `stock` with the Mac's color in the slot of the Mac theme's own look (`pick`'s color), while
    /// the accent follows the Mac. The phone keeps its own light or dark (System follows iOS; Light
    /// and Dark are the person's), and the slot of the other look keeps the stock color: a light
    /// Mac theme on a phone in dark mode shows the stock dark chrome.
    public func token(_ stock: CmuxMobileColorToken, _ pick: (CmuxMobileMacPalette) -> CmuxMobileRGBA) -> CmuxMobileColorToken {
        guard let palette else { return stock }
        let value = pick(palette)
        return palette.isDark
            ? CmuxMobileColorToken(dark: value, light: stock.light, lightHighContrast: stock.lightHighContrast)
            : CmuxMobileColorToken(dark: stock.dark, light: value, darkHighContrast: stock.darkHighContrast)
    }
}
#endif
