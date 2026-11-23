public import Foundation

/// The terminal theme of the machine a terminal session runs on: the Ghostty config lines its Mac
/// sends on the `appearance` service (`terminal`: the value of each of ``keys`` in the Mac's
/// applied Ghostty config; hostd `appearance.rs` keeps them safe). The phone's terminals
/// take every theme value from here and none from the phone: ``configText`` resets each key before
/// loading the Mac's lines, so a key the Mac leaves unset falls back to Ghostty's default.
public struct CmuxMobileTerminalTheme: Equatable, Sendable {
    /// The Ghostty keys of the terminal theme. The Mac sends these
    /// (`GhosttyRuntime.phoneTerminalThemeKeys`) and hostd keeps these (`appearance.rs`
    /// `TERMINAL_KEYS`); keep the three lists the same.
    public static let keys: [String] = [
        "background", "foreground", "palette",
        "cursor-color", "cursor-text", "cursor-opacity",
        "selection-background", "selection-foreground", "bold-color",
        "minimum-contrast", "faint-opacity", "palette-generate", "palette-harmonious",
        "alpha-blending", "window-colorspace",
        "search-background", "search-foreground", "search-selected-background", "search-selected-foreground",
        opacityKey,
    ]
    /// The key hostd writes from the Mac's wallpaper tint (`appearance.rs` `TERMINAL_OPACITY_KEY`):
    /// below 1, the Mac's terminals show its picture under ``background`` at this opacity
    /// (ask-a6804c4472), and so does this phone's terminal page (``seesThrough``).
    public static let opacityKey = "background-opacity"
    /// The longest value kept on one line (hostd's bound).
    static let maxValueLength = 64

    /// `key = value` lines, each a theme key with a plain value.
    public let lines: [String]
    /// `#rrggbb` of the background and foreground lines.
    public let background: String
    public let foreground: String

    /// The theme of `lines`, keeping only well-formed theme lines; nil without a background and a
    /// foreground color.
    public init?(lines: [String]) {
        let kept = lines.compactMap(Self.line)
        func color(_ key: String) -> String? {
            kept.last { $0.hasPrefix("\(key) = #") }.map { String($0.dropFirst(key.count + 3)) }
                .flatMap(Self.hex)
        }
        guard let background = color("background"), let foreground = color("foreground") else { return nil }
        self.lines = kept
        self.background = background
        self.foreground = foreground
    }

    /// The terminal theme of `appearance`: its Mac's terminal lines, else (a Mac that predates
    /// them) the colors its chrome derives from, which are its terminal theme unless it names an
    /// app theme. Nil when neither is usable.
    public init?(appearance: CmuxMobileMacAppearance) {
        if let lines = appearance.terminal, let theme = Self(lines: lines) {
            self = theme
            return
        }
        let theme = appearance.theme
        var lines = ["background = \(theme.background)", "foreground = \(theme.foreground)"]
        lines += theme.palette.enumerated().map { "palette = \($0.offset)=\($0.element)" }
        if let cursor = theme.cursor { lines.append("cursor-color = \(cursor)") }
        if let selection = theme.selectionBackground { lines.append("selection-background = \(selection)") }
        if let selection = theme.selectionForeground { lines.append("selection-foreground = \(selection)") }
        self.init(lines: lines)
    }

    /// The terminal theme of `appearance` as its Mac's terminals show it: ``init(appearance:)``,
    /// and over a wallpaper the window's tint as ``opacityKey`` when hostd (an older one) sent no
    /// such line, so the picture shows behind the terminal as it does on the Mac.
    public init?(showing appearance: CmuxMobileMacAppearance) {
        guard var theme = Self(appearance: appearance) else { return nil }
        if let wallpaper = appearance.wallpaper, !theme.lines.contains(where: { $0.hasPrefix("\(Self.opacityKey) =") }),
           let tinted = Self(lines: theme.lines + ["\(Self.opacityKey) = \(min(max(wallpaper.tintOpacity, 0), 1))"]) {
            theme = tinted
        }
        self = theme
    }

    /// The Mac's terminal background opacity (``opacityKey``), 0...1; 1 (opaque) when unset.
    public var backgroundOpacity: Double {
        let prefix = "\(Self.opacityKey) = "
        guard let line = lines.last(where: { $0.hasPrefix(prefix) }), let value = Double(line.dropFirst(prefix.count)),
              value.isFinite else { return 1 }
        return min(max(value, 0), 1)
    }

    /// Whether the Mac's terminals let its wallpaper through (``backgroundOpacity`` below 1): the
    /// phone's terminal then draws no background of its own and the page behind it paints the
    /// picture under ``background`` at ``backgroundOpacity`` (or the plain background until the
    /// picture is on this phone).
    public var seesThrough: Bool { backgroundOpacity < 1 }

    /// The Ghostty config text that gives a terminal this theme: every theme key (and `theme`, so
    /// no theme file of the phone's loads) reset to Ghostty's default, then the Mac's lines.
    public var configText: String {
        (["theme ="] + Self.keys.map { "\($0) =" } + lines).joined(separator: "\n") + "\n"
    }

    /// Whether the background is dark (relative luminance below one half).
    public var isDark: Bool {
        guard let rgb = Self.rgb(background) else { return true }
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
        return luminance < 0.5
    }

    /// `line` as `key = value` when its key is a theme key and its value is plain (letters,
    /// digits and `#=:.,_-`, the shapes of a color, number, flag, enum or palette entry), or empty.
    static func line(_ line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard keys.contains(key), value.count <= maxValueLength,
              value.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "#=:.,_-".unicodeScalars.contains($0)) })
        else { return nil }
        return value.isEmpty ? "\(key) =" : "\(key) = \(value)"
    }

    /// `#rrggbb`, lowercased, of a `#rrggbb` value.
    static func hex(_ value: String) -> String? {
        rgb(value) == nil ? nil : value.lowercased()
    }

    /// The phone's own terminal look, shown while Settings > Appearance > Match Mac theme is off:
    /// true black with the app's light gray text (the colors of a phone no Mac ever themed).
    public static let stock = CmuxMobileTerminalTheme(lines: ["background = #000000", "foreground = #e6e6e6"])!

    /// The 0...1 components of `#rrggbb`.
    public static func rgb(_ value: String) -> (Double, Double, Double)? {
        guard value.count == 7, value.hasPrefix("#"), let raw = UInt32(value.dropFirst(), radix: 16) else { return nil }
        return (Double((raw >> 16) & 0xFF) / 255, Double((raw >> 8) & 0xFF) / 255, Double(raw & 0xFF) / 255)
    }
}

#if os(iOS)
import OSLog
public import UIKit

private let themeLog = Logger(subsystem: "dev.cmux.mobile", category: "terminal-theme")

extension CmuxMobileTerminalTheme {
    /// The background as an opaque color (the surface, its backing and its card).
    public var backgroundColor: UIColor { Self.color(background) }
    /// The background at ``backgroundOpacity``: the tint over the Mac's picture.
    public var tintColor: UIColor { backgroundColor.withAlphaComponent(backgroundOpacity) }
    public var foregroundColor: UIColor { Self.color(foreground) }
    /// The look of the terminal page's own chrome (keys, glass, keyboard).
    public var interfaceStyle: UIUserInterfaceStyle { isDark ? .dark : .light }

    static func color(_ hex: String) -> UIColor {
        let rgb = rgb(hex) ?? (0, 0, 0)
        return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}

/// Each linked Mac's terminal theme, from its `appearance` frames (``MacAppearanceFeed``), for
/// every terminal of that Mac, whatever Mac the phone focuses. Settings > Appearance > Match Mac
/// theme (on by default) is the override: off, every terminal shows ``CmuxMobileTerminalTheme/stock``.
/// Leo, 2026-11-22: "if you want it different, then it's a toggle."
/// A change posts ``didChange`` with the Mac id under ``macIDKey`` (terminals of that Mac recolor),
/// or with no Mac id when the switch flips (every terminal recolors).
@MainActor
public final class CmuxMobileTerminalThemes {
    public static let shared = CmuxMobileTerminalThemes()
    public static let didChange = Notification.Name("cmuxMobile.terminalThemes.didChange")
    public static let macIDKey = "macID"

    private var byMac: [String: CmuxMobileTerminalTheme] = [:]
    /// The last Mac theme on disk (``CmuxMobileMacAppearanceCache``): a terminal shows it until its
    /// own Mac's first frame, so a cold launch does not flash the phone's default colors.
    private var cached: CmuxMobileTerminalTheme?

    /// Whether terminals show their Mac's theme (Match Mac theme).
    private let followsMac: @MainActor () -> Bool
    private var switchObserver: (any NSObjectProtocol)?

    public init(cached: CmuxMobileMacAppearance? = CmuxMobileMacAppearanceCache.standard.load(),
                macTheme: CmuxMobileMacTheme = .shared) {
        self.cached = cached.flatMap(CmuxMobileTerminalTheme.init(showing:))
        followsMac = { [weak macTheme] in macTheme?.matchesMac ?? true }
        switchObserver = NotificationCenter.default.addObserver(
            forName: CmuxMobileMacTheme.matchesMacDidChange, object: macTheme, queue: nil
        ) { [weak self] _ in
            // The switch is set on the main thread (Settings); recolor there at once.
            let recolor: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
            if Thread.isMainThread { MainActor.assumeIsolated(recolor) } else { Task { @MainActor in recolor() } }
        }
    }

    /// The theme for a terminal of `macID`: that Mac's, else the cached one; nil before any Mac
    /// ever sent one. With Match Mac theme off, ``CmuxMobileTerminalTheme/stock``.
    public func theme(for macID: String?) -> CmuxMobileTerminalTheme? {
        guard followsMac() else { return .stock }
        return macID.flatMap { byMac[$0] } ?? cached
    }

    #if DEBUG
    /// A launch fixture's Mac (``CmuxMobileMacTheme/applyLaunchFixture(arguments:)``): every
    /// terminal with no frame of its own shows it, as the cached Mac's would.
    public func applyFixture(_ appearance: CmuxMobileMacAppearance) {
        cached = CmuxMobileTerminalTheme(showing: appearance)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
    #endif

    /// `macID`'s newest appearance frame.
    public func apply(_ appearance: CmuxMobileMacAppearance, macID: String) {
        guard let theme = CmuxMobileTerminalTheme(showing: appearance), byMac[macID] != theme else { return }
        byMac[macID] = theme
        guard followsMac() else { return }
        themeLog.info("terminal theme of \(macID, privacy: .private(mask: .hash)): \(theme.lines.count) lines, background \(theme.background, privacy: .public), from \(appearance.terminal == nil ? "chrome colors" : "terminal lines", privacy: .public)")
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.macIDKey: macID])
    }
}
#endif
