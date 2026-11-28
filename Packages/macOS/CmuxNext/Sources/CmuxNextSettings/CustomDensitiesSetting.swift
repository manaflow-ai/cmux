public import CmuxNextDesign
import Foundation

/// `appearance.customDensities` in cmux.json: the user's own densities
/// (plans/cmux-next/density-DESIGN.md). Each entry is one ``DensityTokens`` object:
///
/// ```json
/// { "id": "my-tight", "name": "My Tight", "basedOn": "compact",
///   "level": -0.25, "spacing": 0.9, "fontSize": 11.5, "tokens": { "sidebarRowHeight": 22 } }
/// ```
///
/// The same object is a density's export format, and import reads it back.
public nonisolated struct CustomDensitiesSetting: Sendable {
    /// The most custom densities a file keeps.
    public let limit = 64

    public init() {}

    /// The custom densities in `root`, in file order. An entry that is not a valid density, or
    /// whose id repeats or names a built-in, is skipped with a diagnostic.
    public func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> [DensityTokens] {
        let reply = SettingsRust.answer("densities.parse", ["root": root.keeping([Self.configPath])])
        for diagnostic in reply["diagnostics"]?.arrayValue ?? [] {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: diagnostic["path"]?.stringValue ?? Self.configPath.joined(separator: "."), message: diagnostic["message"]?.stringValue ?? "invalid density"))
        }
        return (reply["densities"]?.arrayValue ?? []).compactMap(Self.density)
    }

    /// Whether `value` is a list of valid densities (the Settings write check).
    public static func accepts(_ value: JSONValue) -> Bool {
        SettingsRust.answer("densities.accepts", ["value": value])["valid"]?.boolValue ?? false
    }

    /// One density from its JSON object; nil when it has no valid id or name, or a value of the
    /// wrong type. Numbers out of range are clamped (``DensityTokens/init(id:name:basedOn:level:spacing:fontSize:tokens:)``).
    public static func density(from value: JSONValue) -> DensityTokens? {
        guard let members = SettingsRust.answer("densities.json", ["density": value])["value"]?.objectValue,
              let id = members["id"]?.stringValue, let name = members["name"]?.stringValue else { return nil }
        return DensityTokens(id: id, name: name, basedOn: members["basedOn"]?.stringValue,
                             level: members["level"]?.doubleValue ?? 0, spacing: members["spacing"]?.doubleValue ?? 1,
                             fontSize: members["fontSize"]?.doubleValue,
                             tokens: members["tokens"]?.objectValue?.compactMapValues(\.doubleValue) ?? [:])
    }

    /// The JSON object for `density`: what cmux.json stores and what export writes. Keys at their
    /// default (`spacing` 1, no `fontSize`, no `tokens`) are left out.
    public static func json(_ density: DensityTokens) -> JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(density.id), "name": .string(density.name), "level": .number(density.level),
        ]
        if let basedOn = density.basedOn { members["basedOn"] = .string(basedOn) }
        if density.spacing != 1 { members["spacing"] = .number(density.spacing) }
        if let fontSize = density.fontSize { members["fontSize"] = .number(fontSize) }
        if !density.tokens.isEmpty { members["tokens"] = .object(density.tokens.mapValues(JSONValue.number)) }
        return .object(members)
    }

    /// The cmux.json writes that select `active` (a built-in sets `appearance.density` and clears
    /// `appearance.customDensity`; a custom one sets `appearance.customDensity`), saving `customs` first when given.
    public static func writes(customs: [DensityTokens]?, active: DensityTokens) -> [([String], JSONValue?)] {
        let request: [String: JSONValue] = ["active": json(active)]
            .merging(customs.map { ["customs": .array($0.map(json))] } ?? [:]) { _, new in new }
        return SettingsRust.answer("densities.writes", .object(request))["writes"]?.arrayValue?.compactMap { write in
            guard let path = write["path"]?.arrayValue?.compactMap(\.stringValue) else { return nil }
            return (path, write["value"].flatMap { $0.isNull ? nil : $0 })
        } ?? []
    }

    /// A new custom density made from `base`: named `name` (with `fontSize` when given), with an id made from the name that
    /// none of `existing` uses (`my-tight`, then `my-tight-2`).
    public static func duplicate(_ base: DensityTokens, name: String, fontSize: Double? = nil, existing: [DensityTokens]) -> DensityTokens {
        let request: [String: JSONValue] = ["base": json(base), "name": .string(name), "existing": .array(existing.map(json))]
            .merging(fontSize.map { ["fontSize": .number($0)] } ?? [:]) { _, new in new }
        var copy = density(from: SettingsRust.answer("densities.duplicate", .object(request))["value"] ?? .null) ?? base
        copy.name = name
        return copy
    }

    /// An id for `name`: lowercase letters, digits and hyphens, unique among `existing` and the
    /// built-ins.
    public static func uniqueID(for name: String, existing: [DensityTokens]) -> String {
        SettingsRust.answer("densities.unique_id", ["name": .string(name), "existing": .array(existing.map(json))])["id"]?.stringValue ?? "custom"
    }
}
