// Where the generated request coder's keys can differ from the hand-written requests'
// (p05-ipc tasks 021, 030-043 and 046), read from the request types of the schema,
// through inline and named types alike.
//
// The old coder (CmuxNextDaemon WireCoding) is a JSONEncoder with `.convertToSnakeCase`.
// The strategy renames every key of a keyed container: the request's members and those of
// every nested struct, explicit CodingKeys included. It renames no key of a `[String: V]`
// or of a JSONValue `.object`: JSONEncoder encodes a String-keyed dictionary as itself,
// without the key strategy (`_JSONStringDictionaryEncodableMarker`, swift-foundation
// JSONEncoder.swift). The generated coder writes each keyed member under its wire name.

/// The keyed members whose bytes change and the dictionaries whose keys stay as given.
struct WireKeyInventory: Equatable {
    /// Keyed members whose wire name the old coder could not send, by path
    /// (`command.field.member`), with the snake-case key it sent instead. The generated
    /// coder sends the wire name, so these bytes change.
    let renamedKeys: [String: String]
    /// Paths whose value holds caller-authored keys: a map, a `JsonValue` document or an
    /// object with additional properties. Neither coder renames those keys, so they are
    /// not byte changes. A migration (030-043) checks the hand-written type at each path:
    /// one that held a struct there sent its members' snake-case names, which its caller
    /// must now pass as the keys.
    let dictionaryFields: [String]

    /// `requests`: each served command's wire name and request type.
    init(types: [String: SchemaJSON], requests: [(wire: String, request: SchemaJSON)]) {
        var walker = Walker(types: types)
        for (wire, request) in requests { walker.visit(request, path: wire, inside: []) }
        renamedKeys = walker.renamed
        dictionaryFields = walker.dictionaries.sorted()
    }

    /// Foundation's `convertToSnakeCase` (`_convertToSnakeCase` in swift-foundation
    /// JSONEncoder.swift): words split before a capital, a run of capitals is one word
    /// up to the capital before a lowercase letter, all lowercased and joined with `_`.
    /// Like Foundation it takes the first character as lowercase (`HTTPServer` -> `h_ttp_server`).
    static func snakeCase(_ key: String) -> String {
        let characters = Array(key)
        guard !characters.isEmpty else { return key }
        var words: [String] = []
        var start = 0
        var search = 1
        while let upper = (search..<characters.count).first(where: { characters[$0].isUppercase }) {
            words.append(String(characters[start..<upper]))
            guard let lower = (upper..<characters.count).first(where: { characters[$0].isLowercase }) else {
                start = upper
                break
            }
            if lower == upper + 1 {
                start = upper
            } else {
                words.append(String(characters[upper..<(lower - 1)]))
                start = lower - 1
            }
            search = lower + 1
        }
        words.append(String(characters[start...]))
        return words.map { $0.lowercased() }.joined(separator: "_")
    }
}

/// Walks type expressions, resolving `ref`s through `$.types`.
private struct Walker {
    let types: [String: SchemaJSON]
    var renamed: [String: String] = [:]
    var dictionaries: Set<String> = []

    /// `inside`: the named types on the way to `node`, so a recursive type stops on its path.
    mutating func visit(_ node: SchemaJSON, path: String, inside: Set<String>) {
        switch node["kind"]?.string {
        case "ref":
            guard let name = node["name"]?.string, !inside.contains(name), let declared = types[name] else { return }
            guard declared["kind"]?.string != "opaque_json" else {
                if name == RequestSchema.documentType { dictionaries.insert(path) }
                return
            }
            visit(declared, path: path, inside: inside.union([name]))
        case "alias":
            if let target = node["target"] { visit(target, path: path, inside: inside) }
        case "array":
            if let items = node["items"] { visit(items, path: path, inside: inside) }
        case "map":
            dictionaries.insert(path)
            if let values = node["values"] { visit(values, path: path, inside: inside) }
        case "object":
            if node["additional_properties"]?.bool == true { dictionaries.insert(path) }
            for (wire, member) in node["fields"]?.object ?? [:] {
                let memberPath = "\(path).\(wire)"
                let sent = WireKeyInventory.snakeCase(wire)
                if sent != wire { renamed[memberPath] = sent }
                if let type = member["type"] { visit(type, path: memberPath, inside: inside) }
            }
        case "tagged_union", "untagged_union":
            switch node["variants"] {
            case .object(let variants)?: for variant in variants.values { visit(variant, path: path, inside: inside) }
            case .array(let variants)?: for variant in variants { visit(variant, path: path, inside: inside) }
            default: break
            }
        default:
            break
        }
    }
}
