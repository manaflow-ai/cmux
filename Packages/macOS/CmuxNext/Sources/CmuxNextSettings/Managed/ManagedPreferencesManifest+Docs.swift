public import Foundation

extension ManagedPreferencesManifest {
    /// Keys the example profile sets: each at its default, so installing
    /// the example as-is locks those settings without changing them.
    static var exampleKeys: [String: Any] {
        var keys: [String: Any] = [:]
        for e in entries.prefix(3) {
            if let value = e.defaultValue.flatMap(propertyList) { keys[e.name] = value }
        }
        keys["DisabledFeatures"] = [String]()
        return keys
    }

    // MARK: Example .mobileconfig (any MDM that uploads a custom profile)

    /// Unsigned profile with one `com.manaflow.cmux` payload. Fixed UUIDs keep
    /// it reproducible; replace them (and the keys) before deploying.
    public static func exampleMobileconfig() throws -> Data {
        let payload: [String: Any] = exampleKeys.merging([
            "PayloadType": ManagedPreferences.domain,
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.manaflow.cmux.example.settings",
            "PayloadUUID": "5B0C4E42-7D8A-4C55-9C3E-2D6F4A1B9E01",
            "PayloadDisplayName": "cmux settings"
        ]) { first, _ in first }
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.manaflow.cmux.example",
            "PayloadUUID": "5B0C4E42-7D8A-4C55-9C3E-2D6F4A1B9E00",
            "PayloadDisplayName": "cmux (example)",
            "PayloadDescription": "Example managed settings for cmux. Generated from the settings catalog; see managed-preferences.md.",
            "PayloadScope": "System",
            "PayloadContent": [payload]
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    // MARK: Intune "Preference file" (bare keys, no <plist> or <dict> wrapper)

    public static func intunePreferenceFile() throws -> String {
        let data = try PropertyListSerialization.data(fromPropertyList: exampleKeys, format: .xml, options: 0)
        let xml = String(decoding: data, as: UTF8.self)
        guard let open = xml.range(of: "<dict>\n"), let close = xml.range(of: "</dict>\n</plist>", options: .backwards) else { return xml }
        return xml[open.upperBound..<close.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("\t") ? String($0.dropFirst()) : String($0) }
            .joined(separator: "\n")
    }

    // MARK: Admin documentation

    public static func markdown() -> String {
        var lines = [
            "# cmux managed preferences",
            "",
            "Generated from the cmux settings catalog by `ManagedPreferencesManifest` (CmuxNextSettings). Do not edit by hand; run `CMUX_UPDATE_MDM_SCHEMA=1 swift test --filter ManagedPreferencesManifestTests` in `Packages/macOS/CmuxNext`.",
            "",
            "Domain: `\(ManagedPreferences.domain)` for every channel (stable, NIGHTLY, DEV). A forced value (any MDM custom settings payload) locks the setting and Settings shows \"Managed by your organization\". A non-forced value replaces the default and the user can still change it. Precedence, highest first: MDM forced, team policy enforced, the user's cmux.json, MDM non-forced, team policy default, product default.",
            "",
            "The legacy forced key `DisableAutoUpdate` in `\(ManagedPreferences.legacyDomain)` keeps working.",
            "",
            "Files: `com.manaflow.cmux.plist` (ProfileManifests: iMazing Profile Editor, ProfileCreator), `com.manaflow.cmux.json` (Jamf Pro custom schema), `cmux-example.mobileconfig` (any MDM), `com.manaflow.cmux.intune.plist` (Intune preference file).",
            "",
            "| Key | Type | Default | Allowed values | Description |",
            "| --- | --- | --- | --- | --- |"
        ]
        for e in entries {
            let allowed: String = {
                if !e.choices.isEmpty { return e.choices.map { "`\($0)`" }.joined(separator: ", ") }
                if let r = e.range { return "\(format(r.lowerBound)) to \(format(r.upperBound))" }
                if !e.members.isEmpty { return e.members.map { "`\($0)`: HH:MM" }.joined(separator: ", ") }
                return ""
            }()
            let fallback = e.defaultValue.map { "`\($0.compactText)`" } ?? ""
            let help = e.help.replacingOccurrences(of: "|", with: "\\|")
            lines.append("| `\(e.name)` | \(e.type.rawValue) | \(fallback) | \(allowed) | \(e.title == e.name ? help : (help.isEmpty ? e.title : "\(e.title). \(help)")) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}
