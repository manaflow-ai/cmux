/// `terminal.cursorStyle` and `terminal.cursorBlink`: the terminal cursor's shape and blink over the
/// Ghostty config's `cursor-style` and `cursor-style-blink`. Unset keeps the Ghostty config's; a
/// bad value is unset plus a diagnostic. Paths and values are generated from
/// schemas/settings/source/terminal.json.
public nonisolated struct TerminalCursorSetting: Hashable, Sendable {
    /// A Ghostty `cursor-style` (`block`, `bar`, `underline`, `block_hollow`), nil for the config's.
    public var style: String?
    /// Ghostty `cursor-style-blink`, nil for the config's.
    public var blink: Bool?

    public init(style: String? = nil, blink: Bool? = nil) {
        self.style = style
        self.blink = blink
    }

    public static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> TerminalCursorSetting {
        var setting = TerminalCursorSetting()
        if let value = root.value(at: cursorStylePath), value != .null {
            if let text = value.stringValue, cursorStyleValues.contains(text) {
                setting.style = text
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: cursorStylePath.joined(separator: "."),
                                                      message: "expected one of \(cursorStyleValues.map { "\"\($0)\"" }.joined(separator: ", "))"))
            }
        }
        if let value = root.value(at: cursorBlinkPath), value != .null {
            if let text = value.stringValue, cursorBlinkValues.contains(text) {
                setting.blink = text == "on"
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: cursorBlinkPath.joined(separator: "."),
                                                      message: "expected \"on\" or \"off\""))
            }
        }
        return setting
    }

    /// The Ghostty config lines that apply this over the user's config; none when unset.
    public var ghosttyLines: [String] {
        (style.map { ["cursor-style = \($0)"] } ?? []) + (blink.map { ["cursor-style-blink = \($0)"] } ?? [])
    }
}
