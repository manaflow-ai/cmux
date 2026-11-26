public import CmuxNextDesign
import Foundation

/// `appearance.backgroundPlacement`: picture id to where that picture lies (``BackdropPlacement``;
/// Rust `cmux-config` `backdrop_placement` is the spec). Unset, and any picture without an entry,
/// is today's centered fill. Adjust Background… and the Settings page's Background preview write it.
public struct BackdropPlacementSetting: Sendable {
    public init() {}

    /// The placements by picture id; a value that is not a map of placement texts is none plus a
    /// diagnostic, and so is each entry that does not read (the others still apply).
    public static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> [String: BackdropPlacement] {
        guard let value = root.value(at: placementPath) else { return [:] }
        guard let members = value.objectValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.backgroundPlacement",
                                                  message: "expected an object of picture ids to placements, such as {\"munch-scream\": \"fit\"}"))
            return [:]
        }
        var out: [String: BackdropPlacement] = [:]
        for (id, entry) in members {
            let reply = SettingsRust().answer("backdrop.placement", ["action": .string("parse"), "text": entry.stringValue.map(JSONValue.string) ?? .null])
            if !id.trimmingCharacters(in: .whitespaces).isEmpty, let text = reply["value"]?.stringValue,
               let placement = BackdropPlacement(text: text) {
                out[id] = placement
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "appearance.backgroundPlacement.\(id)",
                                                      message: "expected fill, fit, center or stretch, then optionally X Y (0 to 1) and a zoom (1 to 4)"))
            }
        }
        return out
    }

    /// Whether `value` loads with no diagnostic (Rust `is_placement_map`).
    static func accepts(_ value: JSONValue) -> Bool {
        SettingsRust().answer("backdrop.placement", ["action": .string("accepts"), "value": value])["valid"]?.boolValue ?? false
    }

    /// The whole map with `id` set to `placement` (removed for a centered fill, so Reset leaves
    /// no entry), as the file's value; nil when nothing is left.
    public static func value(_ current: [String: BackdropPlacement], setting id: String, to placement: BackdropPlacement) -> JSONValue? {
        var next = current
        next[id] = placement.isCenteredFill ? nil : placement
        guard !next.isEmpty else { return nil }
        return .object(next.mapValues { .string($0.text) })
    }
}
