/// `appearance.themeFileExceptions` in cmux-next.json: the look keys the person changed in Settings
/// while the active theme file sets them (#44894). The theme file applies over cmux-next.json except
/// at these keys, where the person's own value applies, so a Settings change never saves and then
/// shows the file's value instead. Resetting such a row drops its key (the file's value returns), and
/// choosing another theme file (or none) clears the list: a new look applies whole.
public nonisolated struct ThemeFileExceptionsSetting: Sendable {
    public init() {}

    /// Keys whose theme file entries never take part in an exception: the theme file's colors
    /// become `appearance.themeEdits` entries merged with the person's (`ThemeFileOverlay`), so a
    /// whole-map exception would drop the file's colors.
    static let unexceptionable: Set<String> = ["appearance.themeEdits"]

    /// The dotted keys in `root`'s list, without repeats; a missing or bad value is none.
    /// Entries that are no look setting a theme file may set, or that never take an exception
    /// (``unexceptionable``), are ignored: a hand-written `"appearance"` must not switch the whole
    /// file off. Rust answers (`theme.exceptions`).
    public static func keys(in root: JSONValue) -> Set<String> {
        Set(SettingsRust().answer("theme.exceptions", .object(["root": root]))["keys"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    /// The list edit for writing `writes` (dotted key, whether the write sets a value) while `overlay`
    /// is the active theme file, read against `root` (the document before the write). A set adds
    /// each key the file sets, a reset removes it; choosing a theme file clears the list. Rust answers
    /// (`theme.exception_edit`).
    ///
    /// - Returns: The new list value, or `.some(nil)` to remove the key, or nil for no edit.
    static func edit(writing writes: [(key: String, sets: Bool)], overlay: ThemeFileOverlay?,
                     in root: JSONValue) -> JSONValue?? {
        var request: [String: JSONValue] = [
            "root": root,
            "writes": .array(writes.map { .object(["key": .string($0.key), "sets": .bool($0.sets)]) }),
        ]
        if let overlay { request["file_keys"] = .array(overlay.values.map { .string($0.path.joined(separator: ".")) }) }
        let reply = SettingsRust().answer("theme.exception_edit", .object(request))
        guard reply["change"]?.boolValue == true, let value = reply["value"] else { return nil }
        if case .null = value { return .some(nil) }
        return .some(value)
    }
}
