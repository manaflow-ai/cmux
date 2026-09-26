import Foundation

/// Answers "does cmux.json declare this dotted path, and what is its default?"
/// from the same embedded schema ``CmuxConfigSemanticValidator`` uses.
///
/// A path is declared when every component resolves through `properties`,
/// a matching `patternProperties` entry, or an object-valued
/// `additionalProperties` schema, following `$ref` and the alternatives of
/// `allOf`, `anyOf`, and `oneOf`. Writers use it to reject a mistyped path
/// before touching the file, and to find the effective value of a key the
/// file doesn't set.
public struct CmuxConfigSchemaPathLookup {
    private let rootSchema: [String: Any]

    public init() {
        self.init(schema: .embedded)
    }

    init(schema: CmuxParsedConfigSchema) {
        self.rootSchema = schema.root
    }

    /// Whether the schema declares `components` as a property path.
    public func isDeclared(_ components: [String]) -> Bool {
        !components.isEmpty && !schemas(at: components).isEmpty
    }

    /// The schema `default` for `components`, or nil when the path is
    /// undeclared or has no default. `null` defaults are returned as `NSNull`.
    public func defaultValue(at components: [String]) -> Any? {
        for schema in schemas(at: components) {
            if let value = defaultValue(in: schema, depth: 0) {
                return value
            }
        }
        return nil
    }

    private func defaultValue(in schema: [String: Any], depth: Int) -> Any? {
        if let value = schema["default"] {
            return value
        }
        guard depth < 16 else { return nil }
        if let ref = schema["$ref"] as? String, let target = resolvedReference(ref) {
            return defaultValue(in: target, depth: depth + 1)
        }
        return nil
    }

    /// Every schema that can describe the value at `components`.
    private func schemas(at components: [String]) -> [[String: Any]] {
        var current: [[String: Any]] = [rootSchema]
        for component in components {
            var next: [[String: Any]] = []
            for schema in current {
                next.append(contentsOf: childSchemas(named: component, in: schema, depth: 0))
            }
            guard !next.isEmpty else { return [] }
            current = next
        }
        return current
    }

    private func childSchemas(
        named key: String,
        in schema: [String: Any],
        depth: Int
    ) -> [[String: Any]] {
        guard depth < 16 else { return [] }
        var matches: [[String: Any]] = []
        if let properties = schema["properties"] as? [String: Any],
           let child = properties[key] as? [String: Any] {
            matches.append(child)
        }
        if let patterns = schema["patternProperties"] as? [String: Any] {
            for (pattern, child) in patterns {
                guard let child = child as? [String: Any],
                      matchesPattern(key, pattern: pattern) else { continue }
                matches.append(child)
            }
        }
        if matches.isEmpty, let additional = schema["additionalProperties"] as? [String: Any] {
            matches.append(additional)
        }
        if let ref = schema["$ref"] as? String, let target = resolvedReference(ref) {
            matches.append(contentsOf: childSchemas(named: key, in: target, depth: depth + 1))
        }
        for combinator in ["allOf", "anyOf", "oneOf"] {
            guard let alternatives = schema[combinator] as? [Any] else { continue }
            for case let alternative as [String: Any] in alternatives {
                matches.append(contentsOf: childSchemas(named: key, in: alternative, depth: depth + 1))
            }
        }
        return matches
    }

    private func resolvedReference(_ ref: String) -> [String: Any]? {
        // "#" names the whole document, so a nested object can reuse the root
        // schema (for example a settingPresets entry is a partial cmux.json).
        if ref == "#" { return rootSchema }
        guard ref.hasPrefix("#/") else { return nil }
        var cursor: Any = rootSchema
        for component in ref.dropFirst(2).split(separator: "/") {
            let key = component
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard let dictionary = cursor as? [String: Any], let next = dictionary[key] else {
                return nil
            }
            cursor = next
        }
        return cursor as? [String: Any]
    }

    private func matchesPattern(_ value: String, pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: (value as NSString).length)
        return expression.firstMatch(in: value, range: range) != nil
    }
}
