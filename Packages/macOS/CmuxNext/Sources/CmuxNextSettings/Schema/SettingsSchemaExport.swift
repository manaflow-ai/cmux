public import Foundation

/// The settings schema as data, for the owners and clients that are not
/// Swift: the daemon's config actor embeds it to validate writes, the web
/// Settings page and the Rust CLI and MCP render rows from it
/// (plans/cmux-next/settings-react.md section 2). Checked in at
/// `schemas/settings/settings-schema.json`; `SettingsSchemaExportTests`
/// fails when it is stale (`CMUX_UPDATE_ACTION_SURFACES=1` rewrites it).
///
/// Every text carries its string catalog key beside the English text, so a
/// client localizes from the same xcstrings files the app uses. Every row
/// carries values the Swift validator accepts and refuses, so another
/// validator can prove it agrees.
public struct SettingsSchemaExport {
    public nonisolated init() {}
    /// Format version of the file; bump on an incompatible change.
    public nonisolated let version = 1

    /// A key the export names that the string catalog does not have.
    public struct MissingKeys: Error, CustomStringConvertible {
        public let keys: [String]
        public var description: String { "keys not in Localizable.xcstrings: \(keys.joined(separator: ", "))" }
    }

    /// The keys of a string catalog (`.xcstrings` JSON).
    public nonisolated func catalogKeys(xcstrings data: Data) throws -> Set<String> {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: Any]
        else { throw CocoaError(.coderReadCorrupt) }
        return Set(strings.keys)
    }

    /// The export document as pretty, key-sorted JSON with a trailing newline,
    /// written by `DeterministicJSON` so it is the same on every toolchain.
    /// Throws `MissingKeys` when a text names a key `catalog` lacks.
    public nonisolated func json(catalog: Set<String>) throws -> String {
        var missing: Set<String> = []
        func text(_ text: String, _ key: String?) -> [String: Any] {
            if let key, !catalog.contains(key) { missing.insert(key) }
            return ["text": text, "key": key.map { $0 as Any } ?? NSNull()]
        }
        let sections: [[String: Any]] = SettingsSection.allCases.map { section in
            ["id": section.rawValue, "title": text(section.title, section.titleKey), "symbol": section.symbol]
        }
        let rows: [[String: Any]] = SettingsSchema.all.map { row(for: $0, text: text) }
        let rowsData = Data(try DeterministicJSON().string(rows, pretty: false).utf8)
        let document: [String: Any] = [
            "version": version,
            "schema_hash": SettingsSchemaHash.hex(rowsData),
            "sections": sections,
            "rows": rows,
        ]
        guard missing.isEmpty else { throw MissingKeys(keys: missing.sorted()) }
        return try DeterministicJSON().string(document, pretty: true) + "\n"
    }

    nonisolated func row(for descriptor: SettingDescriptor, text: (String, String?) -> [String: Any]) -> [String: Any] {
        let keys = descriptor.textKeys
        var row: [String: Any] = [
            "key": descriptor.id,
            "path": descriptor.path,
            "section": descriptor.section.rawValue,
            "group": text(descriptor.group, keys.group),
            "title": text(descriptor.title, keys.title),
            "help": descriptor.help.map { text($0, keys.help) as Any } ?? NSNull(),
            "default": descriptor.defaultValue.map(foundation) ?? NSNull(),
            "default_label": descriptor.defaultLabel.map { text($0, keys.defaultLabel) as Any } ?? NSNull(),
            "keywords": descriptor.keywords,
            "agent_settable": SettingsSchema.agentSettable(descriptor) ?? false,
            "agent_refusal": SettingsSchema.agentRefusedKeys[descriptor.id].map { $0.rawValue as Any } ?? NSNull(),
            "kept_on_reset_all": SettingsSchema.keptOnResetAll.contains(descriptor.path),
            "consumers": descriptor.consumers.sorted().map(\.rawValue),
            "page_hidden": descriptor.page != .shown,
        ]
        let samples = SettingsSchemaSamples.samples(for: descriptor)
        row["accepts"] = samples.accept.filter(descriptor.accepts).map(foundation)
        row["refuses"] = samples.refuse.filter { !descriptor.accepts($0) }.map(foundation)
        func choices(_ choices: [SettingChoice]) -> [[String: Any]] {
            choices.map { ["value": $0.value, "title": text($0.title, $0.titleKey)] }
        }
        switch descriptor.kind {
        case .toggle: row["kind"] = "toggle"
        case .choice(let list):
            row["kind"] = "choice"
            row["choices"] = choices(list)
        case .choiceOrNumber(let list, let number):
            row["kind"] = "choice_or_number"
            row["choices"] = choices(list)
            row["range"] = range(number)
        case .number(let number):
            row["kind"] = "number"
            row["range"] = range(number)
        case .color: row["kind"] = "color"
        case .sound: row["kind"] = "sound"
        case .url: row["kind"] = "url"
        case .hostList: row["kind"] = "host_list"
        case .folderList: row["kind"] = "folder_list"
        case .timeRange: row["kind"] = "time_range"
        case .theme: row["kind"] = "theme"
        case .fontFamily: row["kind"] = "font_family"
        case .numberList(let number):
            row["kind"] = "number_list"
            row["range"] = range(number)
        case .stringMap: row["kind"] = "string_map"
        case .stringList: row["kind"] = "string_list"
        }
        // Kinds whose valid values only the app knows (theme names, installed
        // fonts, system sounds): another validator checks them against the
        // value domain the app publishes, not a fixed rule.
        if descriptor.path == BackdropSelectionSetting().configPath {
            row["validation"] = "domain:backdrop_selection"
        } else if BrowserOmnibarSetting.templatePaths.contains(descriptor.path) {
            // Portable: a web address that contains %s or {searchTerms}, or empty.
            row["validation"] = "domain:search_template"
        } else {
            switch descriptor.kind {
            case .theme: row["validation"] = "domain:theme"
            case .fontFamily: row["validation"] = "domain:font_family"
            case .sound: row["validation"] = "domain:sound"
            default: row["validation"] = "portable"
            }
        }
        return row
    }

    nonisolated func range(_ number: SettingNumber) -> [String: Any] {
        let unit: String = switch number.unit {
        case .points: "points"
        case .seconds: "seconds"
        case .minutes: "minutes"
        case .count: "count"
        case .fraction: "fraction"
        }
        return ["min": number.range.lowerBound, "max": number.range.upperBound, "step": number.step,
                "unit": unit, "placeholder": number.placeholder]
    }

    /// `JSONValue` as a Foundation JSON object.
    nonisolated func foundation(_ value: JSONValue) -> Any {
        switch value {
        case .null: NSNull()
        case .bool(let bool): bool
        case .number(let number): number
        case .string(let string): string
        case .array(let items): items.map(foundation)
        case .object(let members): members.mapValues(foundation)
        }
    }
}
