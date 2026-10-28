/// `terminal.term` in cmux.json (Lawrence 2026-10-28): the `TERM` new terminals get. Unset, they get the
/// Ghostty config's explicit `term`, else ``standard``; a name other than ``standard`` applies only where its
/// terminfo entry is installed (the app's `TerminfoLookup`). A bad value is unset plus a diagnostic.
public nonisolated struct TerminalTermSetting: Sendable {
    public let path = ["terminal", "term"]
    /// The `TERM` every tool and every ssh host knows, the schema's default.
    public let standard = "xterm-256color"

    public init() {}

    /// A terminfo name: 1 to 64 letters, digits, `.`, `_`, `+` or `-`, not starting with `.` or `-`
    /// (the rule of the app's `TerminalTermChoice.isValidName`).
    public func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count), let first = name.utf8.first, first != UInt8(ascii: "."), first != UInt8(ascii: "-") else {
            return false
        }
        return name.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")
        }
    }

    /// A missing or empty key is unset with no diagnostic; a value that is not a terminfo name is unset plus a diagnostic.
    func parse(_ root: JSONValue) -> (String?, SettingsDiagnostic?) {
        guard let value = root.value(at: path) else { return (nil, nil) }
        let problem = SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."),
                                         message: "expected a terminfo name such as \"xterm-256color\" or \"xterm-ghostty\"")
        guard let text = value.stringValue else { return (nil, problem) }
        let name = text.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return (nil, nil) }
        guard isValidName(name) else { return (nil, problem) }
        return (name, nil)
    }
}
