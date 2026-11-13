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
    ]
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

    /// The 0...1 components of `#rrggbb`.
    public static func rgb(_ value: String) -> (Double, Double, Double)? {
        guard value.count == 7, value.hasPrefix("#"), let raw = UInt32(value.dropFirst(), radix: 16) else { return nil }
        return (Double((raw >> 16) & 0xFF) / 255, Double((raw >> 8) & 0xFF) / 255, Double(raw & 0xFF) / 255)
    }
}

#if os(iOS)
public import UIKit

extension CmuxMobileTerminalTheme {
    /// The background as an opaque color (the surface, its backing and its card).
    public var backgroundColor: UIColor { Self.color(background) }
    public var foregroundColor: UIColor { Self.color(foreground) }
    /// The look of the terminal page's own chrome (keys, glass, keyboard).
    public var interfaceStyle: UIUserInterfaceStyle { isDark ? .dark : .light }

    static func color(_ hex: String) -> UIColor {
        let rgb = rgb(hex) ?? (0, 0, 0)
        return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}

/// Each linked Mac's terminal theme, from its `appearance` frames (``MacAppearanceFeed``), for
/// every terminal of that Mac, whatever Mac the phone focuses and whatever Settings > Appearance >
/// Match Mac theme says (that switch is the phone's chrome; a terminal shows its machine's colors).
/// A change posts ``didChange`` with the Mac id under ``macIDKey``; terminals of that Mac recolor.
@MainActor
public final class CmuxMobileTerminalThemes {
    public static let shared = CmuxMobileTerminalThemes()
    public static let didChange = Notification.Name("cmuxMobile.terminalThemes.didChange")
    public static let macIDKey = "macID"

    private var byMac: [String: CmuxMobileTerminalTheme] = [:]
    /// The last Mac theme on disk (``CmuxMobileMacAppearanceCache``): a terminal shows it until its
    /// own Mac's first frame, so a cold launch does not flash the phone's default colors.
    private let cached: CmuxMobileTerminalTheme?

    public init(cached: CmuxMobileMacAppearance? = CmuxMobileMacAppearanceCache.standard.load()) {
        self.cached = cached.flatMap(CmuxMobileTerminalTheme.init(appearance:))
    }

    /// The theme for a terminal of `macID`: that Mac's, else the cached one; nil before any Mac
    /// ever sent one.
    public func theme(for macID: String?) -> CmuxMobileTerminalTheme? {
        macID.flatMap { byMac[$0] } ?? cached
    }

    /// `macID`'s newest appearance frame.
    public func apply(_ appearance: CmuxMobileMacAppearance, macID: String) {
        guard let theme = CmuxMobileTerminalTheme(appearance: appearance), byMac[macID] != theme else { return }
        byMac[macID] = theme
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.macIDKey: macID])
    }
}
#endif
