import Foundation

/// Effective values of the Ghostty options Settings > Terminal edits natively.
///
/// Built from every value assigned to each ``GhosttyTerminalOptionKey`` across
/// the resolved config files, in load order (the user's Ghostty config first,
/// cmux's own config after it). The folding mirrors Ghostty: the last valid
/// assignment wins, an empty assignment resets the option to its default, and
/// an invalid assignment leaves the previous value in place. `font-family` is a
/// list, so each assignment appends a fallback and an empty one clears it.
///
/// Only config-file assignments are folded. A value a `theme` file supplies
/// (themes can set `background-opacity`, for example) is not reflected here.
public struct GhosttyTerminalOptions: Equatable, Sendable {
    /// Ghostty's default `font-size` on macOS, in points.
    public static let defaultFontSize = 13.0
    /// Ghostty's default `window-padding-x` and `window-padding-y`, in points.
    public static let defaultWindowPadding = 2
    /// Ghostty's default `scrollback-limit`, in bytes.
    public static let defaultScrollbackLimitBytes = 50_000_000

    /// The font families in fallback order; empty for Ghostty's built-in font.
    public var fontFamilies: [String]
    /// The primary font family, or `nil` for Ghostty's built-in font.
    public var fontFamily: String? { fontFamilies.first }
    /// The terminal font size, in points.
    public var fontSize: Double
    /// The default cursor shape.
    public var cursorStyle: GhosttyCursorStyle
    /// Whether the cursor blinks by default. Ghostty blinks when unset.
    public var cursorBlinks: Bool
    /// Horizontal padding between the terminal cells and the window edge.
    public var windowPaddingX: GhosttyWindowPadding
    /// Vertical padding between the terminal cells and the window edge.
    public var windowPaddingY: GhosttyWindowPadding
    /// Background opacity from 0 (clear) to 1 (opaque).
    public var backgroundOpacity: Double
    /// Whether the translucent background is blurred.
    public var backgroundBlurEnabled: Bool
    /// Which Option keys act as Alt.
    public var optionAsAlt: GhosttyOptionAsAlt
    /// Scrollback memory limit per terminal, in bytes.
    public var scrollbackLimitBytes: Int
    /// Whether a middle click pastes the selection (`middle-click-action`).
    /// Ghostty pastes when unset.
    public var middleClickPaste: Bool

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
        fontFamilies = families

        fontSize = Self.fold(values(.fontSize)) { value in
            Double(value).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        } ?? Self.defaultFontSize
        cursorStyle = Self.fold(values(.cursorStyle), parse: GhosttyCursorStyle.init(rawValue:)) ?? .block
        cursorBlinks = Self.fold(values(.cursorStyleBlink), parse: Self.parseBool) ?? true
        let defaultPadding = GhosttyWindowPadding(leading: Self.defaultWindowPadding)
        windowPaddingX = Self.fold(values(.windowPaddingX), parse: GhosttyWindowPadding.init(configValue:)) ?? defaultPadding
        windowPaddingY = Self.fold(values(.windowPaddingY), parse: GhosttyWindowPadding.init(configValue:)) ?? defaultPadding
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
        middleClickPaste = Self.fold(values(.middleClickAction)) { value in
            switch value {
            case "primary-paste": return true
            case "ignore": return false
            default: return nil
            }
        } ?? true
    }

    /// The options after `change` is written to the last-loaded config file.
    public func applying(_ change: GhosttyTerminalOptionChange) -> GhosttyTerminalOptions {
        var updated = self
        switch change {
        case .fontFamilies(let families): updated.fontFamilies = families
        case .fontSize(let points): updated.fontSize = Self.hundredths(points)
        case .cursorStyle(let style): updated.cursorStyle = style
        case .cursorBlinks(let blinks): updated.cursorBlinks = blinks
        case .windowPaddingX(let points): updated.windowPaddingX = points
        case .windowPaddingY(let points): updated.windowPaddingY = points
        case .backgroundOpacity(let opacity): updated.backgroundOpacity = Self.hundredths(min(max(opacity, 0), 1))
        case .backgroundBlurEnabled(let enabled): updated.backgroundBlurEnabled = enabled
        case .optionAsAlt(let option): updated.optionAsAlt = option
        case .scrollbackLimitBytes(let bytes): updated.scrollbackLimitBytes = bytes
        case .middleClickPaste(let pastes): updated.middleClickPaste = pastes
        }
        return updated
    }

    /// Whether this already holds the value `change` writes, so a re-read
    /// after the write shows whether a later-loading file overrides it.
    public func reflects(_ change: GhosttyTerminalOptionChange) -> Bool {
        applying(change) == self
    }

    /// The family list the font picker writes for `family`: the chosen family
    /// first, then the current fallbacks (without the chosen one), or no
    /// families at all for Ghostty's built-in font.
    public func fontFamiliesChoosing(_ family: String?) -> [String] {
        guard let family, !family.isEmpty else { return [] }
        return [family] + fontFamilies.dropFirst().filter { $0 != family }
    }

    /// Rounds to the two decimals a change writes, so a slider value such as
    /// 0.35000000000000003 matches the 0.35 read back after the write.
    private static func hundredths(_ value: Double) -> Double {
        (value * 100).rounded() / 100
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

    /// `background-blur` accepts a boolean, a radius, or a macOS glass style.
    private static func parseBlur(_ value: String) -> Bool? {
        if let enabled = parseBool(value) { return enabled }
        if value.hasPrefix("macos-glass-") { return true }
        return Int(value).flatMap { $0 >= 0 ? $0 > 0 : nil }
    }
}
