public import CmuxNextDesignTokens
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
    /// The key's path.
    public let configPath = ["appearance", "customDensities"]
    /// The most custom densities a file keeps.
    public let limit = 64

    public init() {}

    /// The custom densities in `root`, in file order. An entry that is not a valid density, or
    /// whose id repeats or names a built-in, is skipped with a diagnostic.
    public func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> [DensityTokens] {
        guard let value = root.value(at: configPath) else { return [] }
        guard case .array(let items) = value else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.customDensities", message: "expected a list of densities"))
            return []
        }
        var result: [DensityTokens] = []
        for (index, item) in items.prefix(limit).enumerated() {
            let path = "appearance.customDensities[\(index)]"
            guard let tokens = Self.density(from: item) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "expected an object with an id and a name"))
                continue
            }
            if DensityPreset(rawValue: tokens.id) != nil || result.contains(where: { $0.id == tokens.id }) {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path, message: "the id \"\(tokens.id)\" is already used"))
                continue
            }
            result.append(tokens)
        }
        return result
    }

    /// Whether `value` is a list of valid densities (the Settings write check).
    public static func accepts(_ value: JSONValue) -> Bool {
        guard case .array(let items) = value else { return false }
        return items.allSatisfy { density(from: $0) != nil }
    }

    /// One density from its JSON object; nil when it has no valid id or name, or a value of the
    /// wrong type. Numbers out of range are clamped (``DensityTokens/init(id:name:basedOn:level:spacing:fontSize:tokens:)``).
    public static func density(from value: JSONValue) -> DensityTokens? {
        guard case .object(let members) = value,
              let id = members["id"]?.stringValue, DensitySetting.isValidID(id),
              let name = members["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }
        func number(_ key: String) -> Double?? {
            guard let raw = members[key] else { return .some(nil) }
            guard let double = raw.doubleValue, double.isFinite else { return nil }
            return .some(double)
        }
        guard let level = number("level"), let spacing = number("spacing"), let fontSize = number("fontSize") else { return nil }
        var tokens: [String: Double] = [:]
        if let raw = members["tokens"] {
            guard case .object(let entries) = raw else { return nil }
            for (key, entry) in entries {
                guard let double = entry.doubleValue, double.isFinite, double >= 0 else { return nil }
                tokens[key] = double
            }
        }
        return DensityTokens(id: id, name: String(name.prefix(64)), basedOn: members["basedOn"]?.stringValue,
                             level: level ?? 0, spacing: spacing ?? 1, fontSize: fontSize, tokens: tokens)
    }

    /// The JSON object for `density`: what cmux.json stores and what export writes. Keys at their
    /// default (`spacing` 1, no `fontSize`, no `tokens`) are left out.
    public static func json(_ density: DensityTokens) -> JSONValue {
        var members: [String: JSONValue] = ["id": .string(density.id), "name": .string(density.name), "level": .number(density.level)]
        if let basedOn = density.basedOn { members["basedOn"] = .string(basedOn) }
        if density.spacing != 1 { members["spacing"] = .number(density.spacing) }
        if let fontSize = density.fontSize { members["fontSize"] = .number(fontSize) }
        if !density.tokens.isEmpty { members["tokens"] = .object(density.tokens.mapValues { .number($0) }) }
        return .object(members)
    }

    /// A new custom density made from `base`: named `name`, with an id made from the name that
    /// none of `existing` uses (`my-tight`, then `my-tight-2`).
    public static func duplicate(_ base: DensityTokens, name: String, existing: [DensityTokens]) -> DensityTokens {
        var copy = base
        copy.name = name
        copy.basedOn = base.isBuiltIn ? base.id : base.basedOn
        copy.id = uniqueID(for: name, existing: existing)
        return copy
    }

    /// An id for `name`: lowercase letters, digits and hyphens, unique among `existing` and the
    /// built-ins.
    public static func uniqueID(for name: String, existing: [DensityTokens]) -> String {
        let characters: [Character] = name.lowercased().map { ($0.isLetter || $0.isNumber) && $0.isASCII ? $0 : "-" }
        let slug = characters.split(separator: "-").map { String($0) }.joined(separator: "-")
        let base = String((slug.isEmpty ? "custom" : slug).prefix(40))
        let taken = Set(existing.map(\.id) + DensityPreset.allCases.map(\.rawValue))
        if !taken.contains(base) { return base }
        var index = 2
        while taken.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }
}
