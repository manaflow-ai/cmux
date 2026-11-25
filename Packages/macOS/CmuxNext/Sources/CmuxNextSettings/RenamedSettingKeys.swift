/// Keys a newer key replaced while the app still applies the old one when the new key is absent.
/// Settings reads the old key's value for the new row (``SettingDescriptor/storedValue(in:)``), and
/// every write or reset of the new row removes the old key, so it never applies again behind it.
/// The renames (schemas/settings/retired-keys.json `replaced_by`, and `appearance.background` over
/// the paintings-only `appearance.backdropArt`) and how an old value reads live in Rust
/// (cmux-config `migrations::renamed`).
nonisolated enum RenamedSettingKeys {
    /// Every renamed row's old key (`migrate.legacy_paths`), read once: rows ask on every read.
    static let renames: [[String]: [String]] = {
        var out: [[String]: [String]] = [:]
        for rename in SettingsRust.answer("migrate.legacy_paths", [:])["renames"]?.arrayValue ?? [] {
            guard let path = rename["path"]?.arrayValue?.compactMap(\.stringValue),
                  let legacy = rename["legacy"]?.arrayValue?.compactMap(\.stringValue) else { continue }
            out[path] = legacy
        }
        return out
    }()

    /// The old key `path` replaced, if any.
    static func legacyPath(for path: [String]) -> [String]? { renames[path] }

    /// The old key's value as the new row shows it: what the app applies from it
    /// (`migrate.legacy_value`). Only the old value crosses to Rust, not the whole file.
    static func legacyValue(for path: [String], in root: JSONValue) -> JSONValue? {
        guard let legacy = renames[path], let value = root.value(at: legacy) else { return nil }
        let only = legacy.reversed().reduce(value) { inner, key in .object([key: inner]) }
        let request: JSONValue = ["path": .array(path.map(JSONValue.string)), "root": only]
        return SettingsRust.answer("migrate.legacy_value", request)["value"]
    }
}
