#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation

/// The `ax` facet (p15-oracle-216, schemas/oracle/snapshot-v1.schema.json `facets.ax`): per window, the
/// accessibility elements a person can focus or act on, in preorder, each with its role, the localization key of
/// its name, whether it is enabled and whether it has the keyboard focus. It is the one facet whose subject is a
/// view tree (p15-oracle.md section 4, rule 7 names model values for the others).
///
/// Chrome's accessibility baselines do the same (content/browser/accessibility/dump_accessibility_tree_browsertest.cc,
/// ui/accessibility/platform/inspect/ax_tree_formatter_mac.mm): a filtered dump of the platform tree in which the
/// nodes the filter drops promote their children, so a wrapper view added or removed by a refactor changes nothing;
/// ``Node/depth`` counts kept ancestors only. Chrome's `*-expected-mac.txt` keep the shown name; this facet keeps
/// the name's localization key instead, so the baseline does not depend on the locale and never holds text a
/// person, a shell or a page wrote (a tab title): a name that is no app string has no key and is recorded as null.
///
/// The host walks the tree in the snapshot's main-actor turn; the keys come after it, off the main actor, from the
/// string tables on disk (``OracleFacetCapture/mainActorThenBackground(_:)``).
public struct OracleAccessibilityFacet: OracleFacetProvider {
    /// One kept element.
    public struct Node: Sendable, Hashable {
        /// The AX role (`AXButton`, `AXTextField`, `AXRow`).
        public var role: String
        /// The texts that name the element, in the order the facet tries them for a key (AX label, title,
        /// placeholder, help). Only a key found for one reaches the facet, never the text.
        public var names: [String]
        public var enabled: Bool
        public var focused: Bool
        /// How many kept elements contain it.
        public var depth: Int

        public init(role: String, names: [String], enabled: Bool, focused: Bool, depth: Int) {
            self.role = role
            self.names = names
            self.enabled = enabled
            self.focused = focused
            self.depth = depth
        }
    }

    /// One window's kept elements.
    public struct Window: Sendable, Hashable {
        /// The public window id (`win_…`), as `snapshot.get` prints it.
        public var id: String
        /// Preorder.
        public var nodes: [Node]

        public init(id: String, nodes: [Node]) {
            self.id = id
            self.nodes = nodes
        }
    }

    /// One compiled string table (`<Table>.strings` of a bundle's `.lproj`): a property list of key to text.
    public struct StringTable: Sendable, Hashable {
        /// The table's file name, for the error that names a table that does not parse.
        public var name: String
        public var data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    public var facet: OracleFacet { .ax }
    public let capture: OracleFacetCapture

    /// - Parameters:
    ///   - read: Walks every window's tree now, in the snapshot's main-actor turn.
    ///   - keys: The localization key of each of the given texts that is the shown text of an app string, read off
    ///     the main actor; a text with none is absent. Called only when some node has a name.
    public init(read: @escaping @MainActor @Sendable () throws(OracleFacetError) -> [Window],
                keys: @escaping @Sendable (Set<String>) async throws(OracleFacetError) -> [String: String]) {
        capture = .mainActorThenBackground { () throws(OracleFacetError) -> OracleFacetFinish in
            let windows = try read()
            return { () async throws(OracleFacetError) -> OracleValue in
                let names = Set(windows.flatMap { $0.nodes.flatMap(\.names) })
                guard !names.isEmpty else { return Self.value(windows, keys: [:]) }
                return Self.value(windows, keys: try await keys(names))
            }
        }
    }

    /// The facet's object: each node's `labelKey` is the key of its first name that has one, else null.
    public static func value(_ windows: [Window], keys: [String: String]) -> OracleValue {
        ["windows": .array(windows.map { window -> OracleValue in
            ["window": .string(window.id), "nodes": .array(window.nodes.map { node -> OracleValue in
                [
                    "role": .string(node.role),
                    "labelKey": node.names.lazy.compactMap { keys[$0] }.first.map(OracleValue.string) ?? .null,
                    "enabled": .bool(node.enabled),
                    "focused": .bool(node.focused),
                    "depth": OracleValue(node.depth),
                ]
            })]
        })]
    }

    /// The key of each of `names` that a table maps to that text. A text that several keys show (`Close` in two
    /// tables) takes the smallest key, so the answer does not depend on the order the tables were read in.
    ///
    /// - Throws: when a table is not a property list of strings: its names would otherwise turn null unseen.
    public static func keys(for names: Set<String>, in tables: [StringTable]) throws(OracleFacetError) -> [String: String] {
        var keys: [String: String] = [:]
        for table in tables {
            let parsed = try? PropertyListSerialization.propertyList(from: table.data, format: nil)
            guard let strings = parsed as? [String: Any] else {
                throw OracleFacetError("string table \(table.name) is not a property list of strings")
            }
            for (key, value) in strings {
                guard let text = value as? String, names.contains(text) else { continue }
                if let kept = keys[text], kept <= key { continue }
                keys[text] = key
            }
        }
        return keys
    }
}
#endif
