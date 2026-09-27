import Foundation

/// Effective values of the Ghostty options Settings > Terminal edits natively.
///
/// Built from every value assigned to each ``GhosttyTerminalOptionKey`` across
/// the resolved config files, in load order (the user's Ghostty config first,
/// cmux's own config after it). The folding mirrors Ghostty: the last valid
/// assignment wins, an empty assignment resets the option to its default, and
/// an invalid assignment leaves the previous value in place. `font-family` is a
/// list, so each assignment appends a fallback and an empty one clears it.
public struct GhosttyTerminalOptions: Equatable, Sendable {
    /// Ghostty's default `font-size` on macOS, in points.
    public static let defaultFontSize = 13.0
    /// Ghostty's default `window-padding-x` and `window-padding-y`, in points.
    public static let defaultWindowPadding = 2
    /// Ghostty's default `scrollback-limit`, in bytes.
    public static let defaultScrollbackLimitBytes = 50_000_000

    /// The primary font family, or `nil` for Ghostty's built-in font.
    public var fontFamily: String?
    /// The terminal font size, in points.
    public var fontSize: Double
    /// The default cursor shape.
    public var cursorStyle: GhosttyCursorStyle
    /// Whether the cursor blinks by default. Ghostty blinks when unset.
    public var cursorBlinks: Bool
    /// Horizontal padding between the terminal cells and the window edge, in
    /// points. For a `left,right` pair this is the left value.
    public var windowPaddingX: Int
    /// Vertical padding between the terminal cells and the window edge, in
    /// points. For a `top,bottom` pair this is the top value.
    public var windowPaddingY: Int
    /// Background opacity from 0 (clear) to 1 (opaque).
    public var backgroundOpacity: Double
    /// Whether the translucent background is blurred.
    public var backgroundBlurEnabled: Bool
    /// Which Option keys act as Alt.
    public var optionAsAlt: GhosttyOptionAsAlt
    /// Scrollback memory limit per terminal, in bytes.
    public var scrollbackLimitBytes: Int

    /// Ghostty's defaults, as seen when no config file sets any of these keys.
    public static let defaults = GhosttyTerminalOptions(directives: [:])

    /// The config keys to collect from the resolved config files.
    public static var configKeys: Set<String> {
        Set(GhosttyTerminalOptionKey.allCases.map(\.rawValue))
    }

    /// Folds the values assigned to each key, in config load order, into the
    /// effective options.
    ///
    /// - Parameter directives: Unquoted values per Ghostty config key, in the
    ///   order Ghostty loads them. Keys other than
    ///   ``GhosttyTerminalOptionKey`` are ignored.
    public init(directives: [String: [String]]) {
        func values(_ key: GhosttyTerminalOptionKey) -> [String] {
            (directives[key.rawValue] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
        }

        var families: [String] = []
        for value in values(.fontFamily) {
            if value.isEmpty { families.removeAll() } else { families.append(value) }
        }
        fontFamily = families.first

        fontSize = Self.fold(values(.fontSize)) { value in
            Double(value).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        } ?? Self.defaultFontSize
        cursorStyle = Self.fold(values(.cursorStyle), parse: GhosttyCursorStyle.init(rawValue:)) ?? .block
        cursorBlinks = Self.fold(values(.cursorStyleBlink), parse: Self.parseBool) ?? true
        windowPaddingX = Self.fold(values(.windowPaddingX), parse: Self.parsePadding) ?? Self.defaultWindowPadding
        windowPaddingY = Self.fold(values(.windowPaddingY), parse: Self.parsePadding) ?? Self.defaultWindowPadding
        backgroundOpacity = Self.fold(values(.backgroundOpacity)) { value in
            Double(value).flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        } ?? 1
        backgroundBlurEnabled = Self.fold(values(.backgroundBlur), parse: Self.parseBlur) ?? false
        optionAsAlt = Self.fold(values(.macosOptionAsAlt)) { value in
            GhosttyOptionAsAlt(rawValue: value).flatMap { $0 == .automatic ? nil : $0 }
        } ?? .automatic
        scrollbackLimitBytes = Self.fold(values(.scrollbackLimit)) { value in
            Int(value.replacingOccurrences(of: "_", with: "")).flatMap { $0 >= 0 ? $0 : nil }
        } ?? Self.defaultScrollbackLimitBytes
    }

    /// The options after `change` is written to the last-loaded config file.
    public func applying(_ change: GhosttyTerminalOptionChange) -> GhosttyTerminalOptions {
        var updated = self
        switch change {
        case .fontFamily(let family): updated.fontFamily = family
        case .fontSize(let points): updated.fontSize = points
        case .cursorStyle(let style): updated.cursorStyle = style
        case .cursorBlinks(let blinks): updated.cursorBlinks = blinks
        case .windowPaddingX(let points): updated.windowPaddingX = points
        case .windowPaddingY(let points): updated.windowPaddingY = points
        case .backgroundOpacity(let opacity): updated.backgroundOpacity = opacity
        case .backgroundBlurEnabled(let enabled): updated.backgroundBlurEnabled = enabled
        case .optionAsAlt(let option): updated.optionAsAlt = option
        case .scrollbackLimitBytes(let bytes): updated.scrollbackLimitBytes = bytes
        }
        return updated
    }

    /// The last valid value, or `nil` when unset or reset by an empty value.
    private static func fold<Value>(_ values: [String], parse: (String) -> Value?) -> Value? {
        var result: Value?
        for value in values {
            if value.isEmpty {
                result = nil
            } else if let parsed = parse(value) {
                result = parsed
            }
        }
        return result
    }

    /// Ghostty's boolean spellings.
    private static func parseBool(_ value: String) -> Bool? {
        switch value {
        case "true", "t", "T", "1": return true
        case "false", "f", "F", "0": return false
        default: return nil
        }
    }

    /// The first side of a `window-padding-*` value (`2` or `2,4`).
    private static func parsePadding(_ value: String) -> Int? {
        let first = value.split(separator: ",", maxSplits: 1).first.map(String.init) ?? value
        return Int(first.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil }
    }

    /// `background-blur` accepts a boolean, a radius, or a macOS glass style.
    private static func parseBlur(_ value: String) -> Bool? {
        if let enabled = parseBool(value) { return enabled }
        if value.hasPrefix("macos-glass-") { return true }
        return Int(value).flatMap { $0 >= 0 ? $0 > 0 : nil }
    }
}
