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
    public static func keys(in root: JSONValue) -> Set<String> {
        Set((root.value(at: configPath)?.arrayValue ?? []).compactMap(\.stringValue))
    }

    /// The list edit for writing `writes` (dotted key, whether the write sets a value) while `overlay`
    /// is the active theme file, read against `root` (the document before the write). A set adds
    /// each key the file sets, a reset removes it; choosing a theme file clears the list. Nil when the
    /// list stays as it is.
    ///
    /// - Returns: The new list value, or `.some(nil)` to remove the key, or nil for no edit.
    static func edit(writing writes: [(key: String, sets: Bool)], overlay: ThemeFileOverlay?,
                     in root: JSONValue) -> JSONValue?? {
        let current = keys(in: root)
        let themeFileKey = ThemeFileSetting.configPath.joined(separator: ".")
        var next = current
        if writes.contains(where: { $0.key == themeFileKey }) {
            next = []
        } else if let overlay {
            let fileKeys = Set(overlay.values.map { $0.path.joined(separator: ".") })
            for write in writes where !unexceptionable.contains(write.key) {
                if write.sets {
                    if fileKeys.contains(write.key) { next.insert(write.key) }
                } else {
                    next.remove(write.key)
                }
            }
        } else {
            for write in writes where !write.sets { next.remove(write.key) }
        }
        guard next != current else { return nil }
        return .some(next.isEmpty ? nil : .array(next.sorted().map(JSONValue.string)))
    }
}
