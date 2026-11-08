import Foundation

/// Reads the static parts of a WezTerm config (`wezterm.lua`).
///
/// WezTerm configs are Lua programs. Only literal top-level assignments are
/// imported; anything computed or conditional is listed as skipped.
public struct WezTermConfigParser: Sendable {
    /// Creates a parser.
    public init() {}

    /// Parses WezTerm config source.
    ///
    /// - Parameters:
    ///   - source: The Lua file's text.
    ///   - profileName: The file name, for the report.
    /// - Returns: The settings read from literal assignments.
    public func parse(source: String, profileName: String? = "wezterm.lua") -> ImportedTerminalSettings {
        let lua = LuaStaticConfigReader().read(source)
        let values = lua.values
        var settings = ImportedTerminalSettings(source: .wezTerm, profileName: profileName)

        switch values["font"] {
        case .font(let family)?, .string(let family)?:
            settings.fontName = family
        default:
            break
        }
        settings.fontSize = values["font_size"]?.number

        if let colors = values["colors"] {
            func color(_ key: String) -> TerminalColor? {
                colors[key]?.string.flatMap { TerminalColor(hex: $0) }
            }
            for (offset, entry) in (colors["ansi"]?.positional ?? []).prefix(8).enumerated() {
                if let value = entry.string.flatMap({ TerminalColor(hex: $0) }) { settings.colors.palette[offset] = value }
            }
            for (offset, entry) in (colors["brights"]?.positional ?? []).prefix(8).enumerated() {
                if let value = entry.string.flatMap({ TerminalColor(hex: $0) }) { settings.colors.palette[offset + 8] = value }
            }
            settings.colors.foreground = color("foreground")
            settings.colors.background = color("background")
            settings.colors.cursor = color("cursor_bg")
            settings.colors.cursorText = color("cursor_fg")
            settings.colors.selectionBackground = color("selection_bg")
            settings.colors.selectionForeground = color("selection_fg")
        }
        if let scheme = values["color_scheme"]?.string {
            settings.unmapped.append(
                "color_scheme \"\(scheme)\" is a WezTerm built-in scheme, so its colors are not in your config. If Ghostty has a theme of that name, run: cmux themes set \"\(scheme)\""
            )
        }

        if let style = values["default_cursor_style"]?.string {
            let lower = style.lowercased()
            if lower.hasSuffix("block") { settings.cursorShape = .block }
            if lower.hasSuffix("bar") { settings.cursorShape = .bar }
            if lower.hasSuffix("underline") { settings.cursorShape = .underline }
            settings.cursorBlink = lower.hasPrefix("blinking")
        }
        if values["cursor_blink_rate"]?.number == 0 {
            settings.cursorBlink = false
        }

        let leftComposes = values["send_composed_key_when_left_alt_is_pressed"]?.bool
        let rightComposes = values["send_composed_key_when_right_alt_is_pressed"]?.bool
        if leftComposes != nil || rightComposes != nil {
            // WezTerm defaults: left Option acts as Alt, right Option composes.
            settings.optionAsAlt = .init(left: !(leftComposes ?? false), right: !(rightComposes ?? true))
        }

        if let padding = values["window_padding"] {
            settings.paddingLeft = points(padding["left"], key: "window_padding.left", settings: &settings)
            settings.paddingRight = points(padding["right"], key: "window_padding.right", settings: &settings)
            settings.paddingTop = points(padding["top"], key: "window_padding.top", settings: &settings)
            settings.paddingBottom = points(padding["bottom"], key: "window_padding.bottom", settings: &settings)
        }
        settings.backgroundOpacity = values["window_background_opacity"]?.number
        if let blur = values["macos_window_background_blur"]?.number {
            settings.backgroundBlur = ConfigValue.int(blur)
        }
        if let lines = values["scrollback_lines"]?.number {
            settings.scrollbackLines = ConfigValue.int(lines)
        }
        if values["line_height"] != nil {
            settings.unmapped.append("line_height is not imported (see Ghostty's adjust-cell-height).")
        }

        let computed = Array(Set(lua.computedKeys)).sorted()
        if !computed.isEmpty {
            settings.unmapped.append("Skipped values computed in Lua: \(computed.joined(separator: ", ")).")
        }
        let conditional = Array(Set(lua.conditionalKeys)).sorted()
        if !conditional.isEmpty {
            settings.unmapped.append("Skipped values set inside Lua logic (if/for/functions): \(conditional.joined(separator: ", ")).")
        }
        return settings
    }

    /// Padding as points: numbers and `"Npx"`/`"Npt"` strings; `cell` and `%` units can't be converted.
    private func points(_ value: LuaValue?, key: String, settings: inout ImportedTerminalSettings) -> Double? {
        switch value {
        case .number(let number)?:
            return number
        case .string(let text)?:
            let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
            for suffix in ["px", "pt"] where lower.hasSuffix(suffix) {
                return ConfigValue.decimal(String(lower.dropLast(suffix.count)))
            }
            settings.unmapped.append("\(key) = \"\(text)\" uses a unit Ghostty has no equivalent for.")
            return nil
        default:
            return nil
        }
    }
}
