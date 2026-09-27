/// One edit from a Settings > Terminal row, and the config lines it writes.
///
/// Each change owns a single Ghostty key. cmux writes it to its own config,
/// which Ghostty loads after the user's, so the change overrides a value the
/// user set in `~/.config/ghostty/config` without editing that file.
public enum GhosttyTerminalOptionChange: Equatable, Sendable {
    /// A primary font family, or `nil` for Ghostty's built-in font.
    case fontFamily(String?)
    case fontSize(Double)
    case cursorStyle(GhosttyCursorStyle)
    case cursorBlinks(Bool)
    case windowPaddingX(Int)
    case windowPaddingY(Int)
    case backgroundOpacity(Double)
    case backgroundBlurEnabled(Bool)
    case optionAsAlt(GhosttyOptionAsAlt)
    case scrollbackLimitBytes(Int)

    /// The Ghostty key this change writes.
    public var key: GhosttyTerminalOptionKey {
        switch self {
        case .fontFamily: return .fontFamily
        case .fontSize: return .fontSize
        case .cursorStyle: return .cursorStyle
        case .cursorBlinks: return .cursorStyleBlink
        case .windowPaddingX: return .windowPaddingX
        case .windowPaddingY: return .windowPaddingY
        case .backgroundOpacity: return .backgroundOpacity
        case .backgroundBlurEnabled: return .backgroundBlur
        case .optionAsAlt: return .macosOptionAsAlt
        case .scrollbackLimitBytes: return .scrollbackLimit
        }
    }

    /// The values to write for ``key``, one `key = value` line each, in order.
    ///
    /// `font-family` appends a fallback on every assignment, so the font
    /// change first writes an empty value to clear families set by earlier
    /// config files and then the chosen family.
    public var configValues: [String] {
        let numberFormatter = CmuxGhosttyConfigSettingEditor()
        switch self {
        case .fontFamily(let family):
            let reset = "\"\""
            guard let family, !family.isEmpty else { return [reset] }
            return [reset, "\"\(family)\""]
        case .fontSize(let points):
            return [numberFormatter.formattedFontSize(points)]
        case .cursorStyle(let style):
            return [style.rawValue]
        case .cursorBlinks(let blinks):
            return [blinks ? "true" : "false"]
        case .windowPaddingX(let points), .windowPaddingY(let points):
            return [String(max(points, 0))]
        case .backgroundOpacity(let opacity):
            return [numberFormatter.formattedFontSize(min(max(opacity, 0), 1))]
        case .backgroundBlurEnabled(let enabled):
            return [enabled ? "true" : "false"]
        case .optionAsAlt(let option):
            return [option.rawValue]
        case .scrollbackLimitBytes(let bytes):
            return [String(max(bytes, 0))]
        }
    }
}
