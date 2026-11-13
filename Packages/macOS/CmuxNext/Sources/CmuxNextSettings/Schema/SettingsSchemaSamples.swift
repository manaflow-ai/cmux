import Foundation

/// Values the schema export lists per row as accepted and refused
/// (schemas/settings/source/samples.json, SettingsSchema+Samples.generated.swift):
/// the export keeps the ones `SettingDescriptor.accepts` accepts under
/// `accepts` and the ones it refuses under `refuses`, so another validator
/// (the daemon's config actor) can prove it agrees with Swift on every row.
nonisolated enum SettingsSchemaSamples {
    /// Values to accept and values to refuse, with `{"$sample": NAME}` placeholders.
    struct SampleSet: Sendable {
        let accept: [JSONValue]
        let refuse: [JSONValue]
    }

    /// The samples of an exported row (`SettingsSchemaExport.row(for:text:)`): its validation
    /// domain's set, else its kind's (`choice_list` for a `string_list` row with choices), with
    /// the placeholders filled from the row's choices, range and `url_key`.
    static func samples(row: [String: Any]) -> (accept: [JSONValue], refuse: [JSONValue]) {
        let kind = row["kind"] as? String ?? ""
        let name = kind == "string_list" && row["choices"] != nil ? "choice_list" : kind
        guard let set = (row["validation"] as? String).flatMap({ domains[$0] }) ?? kinds[name] else { return ([], []) }
        let choices = (row["choices"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }
        let range = row["range"] as? [String: Any]
        let low = range?["min"] as? Double ?? 0, high = range?["max"] as? Double ?? 0, span = max(high - low, 1)
        let urlKey = row["url_key"] as? String ?? ""
        func values(_ name: String) -> [JSONValue] {
            switch name {
            case "choices": choices.map { .string($0) }
            case "choices_reversed": choices.reversed().map { .string($0) }
            case "first_choice": [.string(choices.first ?? "a")]
            case "min": [.number(low)]
            case "max": [.number(high)]
            case "mid": [.number(low + (high - low) / 2)]
            case "below": [.number(low - span)]
            case "above": [.number(high + span)]
            case "url_key": [.string(urlKey)]
            default: []
            }
        }
        // A placeholder in a list stands for its values; `$url_key` names the row's url_key member.
        func fill(_ value: JSONValue) -> [JSONValue] {
            switch value {
            case .object(let members):
                if members.count == 1, case .string(let name)? = members["$sample"] { return values(name) }
                return [.object(Dictionary(uniqueKeysWithValues: members.map {
                    ($0.key == "$url_key" ? urlKey : $0.key, fill($0.value).first ?? .null)
                }))]
            case .array(let items): return [.array(items.flatMap(fill))]
            default: return [value]
            }
        }
        return (set.accept.flatMap(fill), set.refuse.flatMap(fill))
    }
}
