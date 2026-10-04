public import Foundation

/// Generates the published MDM schema (docs/mdm) from the settings catalog
/// plus the managed policy keys, so a new setting is manageable the moment
/// it is in `SettingsSchema` (spec/enterprise.md 5.3). Output is
/// deterministic; `ManagedPreferencesManifestTests` compares it with the
/// checked-in files.
public nonisolated enum ManagedPreferencesManifest {
    /// One manageable key.
    public struct Entry: Sendable, Hashable {
        public enum ValueType: String, Sendable, Hashable {
            case boolean, string, real, array, dictionary
        }

        public let name: String
        public let title: String
        public let help: String
        public let type: ValueType
        /// Allowed values for strings, or for the items of a string array.
        public let choices: [String]
        public let range: ClosedRange<Double>?
        public let defaultValue: JSONValue?
        /// `timeRange` dictionaries: their string members.
        public let members: [String]
    }

    public static let title = "cmux"
    public static let summary = "Managed settings for cmux (every channel). Keys are cmux.json key paths; capitalized keys are policy keys. Forced values lock the setting; non-forced values replace its default."
    /// Bump with any change to the generated schema (ProfileManifests `pfm_version`).
    public static let version = 1
    /// Fixed so the output is reproducible; update with `version`.
    public static let lastModified = Date(timeIntervalSince1970: 1_791_000_000)

    public static var entries: [Entry] {
        SettingsSchema.all.map(entry(for:)) + ManagedPreferences.policyKeys.map(entry(for:))
    }

    static func entry(for d: SettingDescriptor) -> Entry {
        let help = d.help ?? ""
        switch d.kind {
        case .choice(let choices):
            return Entry(name: d.id, title: d.title, help: help, type: .string, choices: choices.map(\.value), range: nil, defaultValue: d.defaultValue, members: [])
        case .choiceOrNumber(let choices, let number):
            // MDM schema editors have no string-or-number type; the choices are offered, a number can be set in a raw profile.
            let more = help.isEmpty ? "" : " "
            let extra = "\(more)Also accepts a number from \(Int(number.range.lowerBound)) to \(Int(number.range.upperBound)) in a raw profile."
            return Entry(name: d.id, title: d.title, help: help + extra, type: .string, choices: choices.map(\.value), range: nil, defaultValue: d.defaultValue, members: [])
        case .toggle:
            return Entry(name: d.id, title: d.title, help: help, type: .boolean, choices: [], range: nil, defaultValue: d.defaultValue, members: [])
        case .number(let number):
            return Entry(name: d.id, title: d.title, help: help, type: .real, choices: [], range: number.range, defaultValue: d.defaultValue, members: [])
        case .color, .sound, .url, .theme, .fontFamily:
            return Entry(name: d.id, title: d.title, help: help, type: .string, choices: [], range: nil, defaultValue: d.defaultValue, members: [])
        case .hostList:
            return Entry(name: d.id, title: d.title, help: help, type: .array, choices: [], range: nil, defaultValue: d.defaultValue, members: [])
        case .timeRange:
            return Entry(name: d.id, title: d.title, help: help, type: .dictionary, choices: [], range: nil, defaultValue: d.defaultValue, members: ["start", "end"])
        }
    }

    static func entry(for key: ManagedPolicyKey) -> Entry {
        switch key.type {
        case .string: Entry(name: key.name, title: key.name, help: key.help, type: .string, choices: [], range: nil, defaultValue: nil, members: [])
        case .boolean: Entry(name: key.name, title: key.name, help: key.help, type: .boolean, choices: [], range: nil, defaultValue: nil, members: [])
        case .choice(let values): Entry(name: key.name, title: key.name, help: key.help, type: .string, choices: values, range: nil, defaultValue: nil, members: [])
        case .stringArray(let values): Entry(name: key.name, title: key.name, help: key.help, type: .array, choices: values, range: nil, defaultValue: nil, members: [])
        }
    }

    // MARK: ProfileManifests (iMazing Profile Editor, ProfileCreator)

    public static func profileManifest() throws -> Data {
        let subkeys: [[String: Any]] = entries.map { e in
            var key: [String: Any] = ["pfm_name": e.name, "pfm_title": e.title, "pfm_type": pfmType(e.type)]
            if !e.help.isEmpty { key["pfm_description"] = e.help }
            if let value = e.defaultValue.flatMap(propertyList) { key["pfm_default"] = value }
            if e.type == .array {
                var item: [String: Any] = ["pfm_name": "Item", "pfm_type": "string"]
                if !e.choices.isEmpty { item["pfm_range_list"] = e.choices }
                key["pfm_subkeys"] = [item]
            } else if !e.choices.isEmpty {
                key["pfm_range_list"] = e.choices
            }
            if let range = e.range {
                key["pfm_range_min"] = range.lowerBound
                key["pfm_range_max"] = range.upperBound
            }
            if !e.members.isEmpty {
                key["pfm_subkeys"] = e.members.map { ["pfm_name": $0, "pfm_type": "string", "pfm_description": "HH:MM"] }
            }
            return key
        }
        let manifest: [String: Any] = [
            "pfm_domain": ManagedPreferences.domain,
            "pfm_title": title,
            "pfm_description": summary,
            "pfm_format_version": 1,
            "pfm_version": version,
            "pfm_last_modified": lastModified,
            "pfm_platforms": ["macOS"],
            "pfm_targets": ["user", "system"],
            "pfm_unique": true,
            "pfm_subkeys": subkeys
        ]
        return try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
    }

    static func pfmType(_ type: Entry.ValueType) -> String {
        switch type {
        case .boolean: "boolean"
        case .string: "string"
        case .real: "real"
        case .array: "array"
        case .dictionary: "dictionary"
        }
    }

    // MARK: Jamf Pro (Application & Custom Settings, custom schema)

    public static func jamfSchema() throws -> Data {
        var properties: [String: Any] = [:]
        for e in entries {
            var p: [String: Any] = ["title": e.title, "description": e.help.isEmpty ? e.name : e.help]
            switch e.type {
            case .boolean: p["type"] = "boolean"
            case .string: p["type"] = "string"
            case .real: p["type"] = "number"
            case .array:
                p["type"] = "array"
                p["items"] = e.choices.isEmpty ? ["type": "string"] : ["type": "string", "enum": e.choices]
            case .dictionary:
                p["type"] = "object"
                p["properties"] = Dictionary(uniqueKeysWithValues: e.members.map { ($0, ["type": "string", "title": $0]) })
            }
            if e.type != .array, !e.choices.isEmpty { p["enum"] = e.choices }
            if let range = e.range {
                p["minimum"] = range.lowerBound
                p["maximum"] = range.upperBound
            }
            if let value = e.defaultValue.flatMap(propertyList) { p["default"] = value }
            properties[e.name] = p
        }
        let schema: [String: Any] = ["title": "\(title) (\(ManagedPreferences.domain))", "description": summary, "properties": properties]
        return Data(try DeterministicJSON().string(schema, pretty: true).utf8)
    }

    /// A JSON value as a property list object (nil has no plist form).
    static func propertyList(_ value: JSONValue) -> Any? {
        switch value {
        case .null: nil
        case .bool(let b): b
        case .number(let n): n.rounded() == n && abs(n) < 1e15 ? Int(n) as Any : n as Any
        case .string(let s): s
        case .array(let items): items.compactMap(propertyList)
        case .object(let members): members.compactMapValues(propertyList)
        }
    }
}
