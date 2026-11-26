/// One edit from a Settings > Terminal row, and the config lines it writes.
///
/// Each change owns a single Ghostty key. cmux writes it to its own config,
/// which Ghostty loads after the user's, so the change overrides a value the
/// user set in `~/.config/ghostty/config` without editing that file.
public enum GhosttyTerminalOptionChange: Equatable, Sendable {
    /// The full family list in fallback order; empty for Ghostty's built-in
    /// font. Build it with ``GhosttyTerminalOptions/fontFamiliesChoosing(_:)``.
    case fontFamilies([String])
    case fontSize(Double)
    case cursorStyle(GhosttyCursorStyle)
    case cursorBlinks(Bool)
    case windowPaddingX(GhosttyWindowPadding)
    case windowPaddingY(GhosttyWindowPadding)
    case backgroundOpacity(Double)
    case backgroundBlurEnabled(Bool)
    case optionAsAlt(GhosttyOptionAsAlt)
    case scrollbackLimitBytes(Int)
    /// Whether a middle click pastes. `false` writes `ignore`; programs that
    /// capture the mouse still receive the click either way.
    case middleClickPaste(Bool)

    /// The Ghostty key this change writes.
    public var key: GhosttyTerminalOptionKey {
        switch self {
        case .fontFamilies: return .fontFamily
        case .fontSize: return .fontSize
        case .cursorStyle: return .cursorStyle
        case .cursorBlinks: return .cursorStyleBlink
        case .windowPaddingX: return .windowPaddingX
        case .windowPaddingY: return .windowPaddingY
        case .backgroundOpacity: return .backgroundOpacity
        case .backgroundBlurEnabled: return .backgroundBlur
        case .optionAsAlt: return .macosOptionAsAlt
        case .scrollbackLimitBytes: return .scrollbackLimit
        case .middleClickPaste: return .middleClickAction
        }
    }

    /// The values to write for ``key``, one `key = value` line each, in order.
    ///
    /// `font-family` appends a fallback on every assignment, so the font
    /// change first writes an empty value to clear families set by earlier
    /// config files and then every family in order.
    public var configValues: [String] {
        let numberFormatter = CmuxGhosttyConfigSettingEditor()
        switch self {
        case .fontFamilies(let families):
            return ["\"\""] + families.map { "\"\($0)\"" }
        case .fontSize(let points):
            return [numberFormatter.formattedFontSize(points)]
        case .cursorStyle(let style):
            return [style.rawValue]
        case .cursorBlinks(let blinks):
            return [blinks ? "true" : "false"]
        case .windowPaddingX(let padding), .windowPaddingY(let padding):
            return [padding.configValue]
        case .backgroundOpacity(let opacity):
            return [numberFormatter.formattedFontSize(min(max(opacity, 0), 1))]
        case .backgroundBlurEnabled(let enabled):
            return [enabled ? "true" : "false"]
        case .optionAsAlt(let option):
            return [option.rawValue]
        case .scrollbackLimitBytes(let bytes):
            return [String(max(bytes, 0))]
        case .middleClickPaste(let pastes):
            return [pastes ? "primary-paste" : "ignore"]
        }
    }
}
