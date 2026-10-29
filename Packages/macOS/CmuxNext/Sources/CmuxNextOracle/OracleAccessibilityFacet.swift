#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation

/// The `ax` facet (schemas/oracle/snapshot-v1.schema.json `facets.ax`): per window, the
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
/// The key an element names itself with (its AX identifier, when that is a key of the app's tables) is recorded as
/// is. Without one, the key is read back from the shown text, and a text that several keys show (`Back`, `Close`) is
/// recorded as ``ambiguousKey``, never as one of its keys picked by a rule the element did not use.
///
/// The host walks the tree in the snapshot's main-actor turn (``OracleAccessibilityWalk``); the keys come after it,
/// off the main actor, from the string tables, read once per facet list
/// (``OracleFacetCapture/split(_:)``).
public struct OracleAccessibilityFacet: OracleFacetProvider {
    /// The `labelKey` of a node whose shown text is the text of several keys and that names no key itself.
    public static let ambiguousKey = "<ambiguous>"

    /// One kept element.
    public struct Node: Sendable, Hashable {
        /// The AX role (`AXButton`, `AXTextField`, `AXRow`).
        public var role: String
        /// The element's AX identifier; it is its key when the app's tables have that key.
        public var identifier: String?
        /// The texts that name the element, in the order the facet tries them for a key (AX label, title,
        /// placeholder, help). Only a key found for one reaches the facet, never the text.
        public var names: [String]
        public var enabled: Bool
        public var focused: Bool
        /// How many kept elements contain it.
        public var depth: Int

        public init(role: String, identifier: String? = nil, names: [String], enabled: Bool, focused: Bool, depth: Int) {
            self.role = role
            self.identifier = identifier
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

    /// The app's keys and, for each shown text, the keys that show it.
    public struct StringIndex: Sendable, Hashable {
        private var keys: Set<String> = []
        private var keysByText: [String: Set<String>] = [:]

        /// - Throws: when a table is not a property list of strings: its names would otherwise turn null unseen.
        public init(_ tables: [StringTable]) throws(OracleFacetError) {
            for table in tables {
                let parsed = try? PropertyListSerialization.propertyList(from: table.data, format: nil)
                guard let strings = parsed as? [String: Any] else {
                    throw OracleFacetError("string table \(table.name) is not a property list of strings")
                }
                for (key, value) in strings {
                    guard let text = value as? String else { continue }
                    keys.insert(key)
                    keysByText[text, default: []].insert(key)
                }
            }
        }

        /// `node`'s key: its identifier when that is a key; else the key of its first name that is an app string's
        /// text, or ``OracleAccessibilityFacet/ambiguousKey`` when several keys show that text; else nil.
        public func labelKey(of node: Node) -> String? {
            if let identifier = node.identifier, keys.contains(identifier) { return identifier }
            guard let shown = node.names.lazy.compactMap({ keysByText[$0] }).first else { return nil }
            return shown.count == 1 ? shown.first : OracleAccessibilityFacet.ambiguousKey
        }
    }

    public var facet: OracleFacet { .ax }
    public let capture: OracleFacetCapture

    /// - Parameters:
    ///   - read: Walks every window's tree now, in the snapshot's main-actor turn.
    ///   - index: Reads the app's string tables, off the main actor. Called once for the facet list, at the first
    ///     snapshot that has a node with a name or an identifier; a failed read is tried again at the next one.
    public init(read: @escaping @MainActor @Sendable () throws(OracleFacetError) -> [Window],
                index: @escaping @Sendable () async throws(OracleFacetError) -> StringIndex) {
        let cache = IndexCache(load: index)
        capture = .split { () throws(OracleFacetError) -> OracleFacetRead in
            let windows = try read()
            return { () async throws(OracleFacetError) -> OracleValue in
                let named = windows.contains { window in window.nodes.contains { !$0.names.isEmpty || $0.identifier != nil } }
                guard named else { return Self.value(windows, index: nil) }
                return Self.value(windows, index: try await cache.index())
            }
        }
    }

    /// The facet's object: each node's `labelKey` from `index` (``StringIndex/labelKey(of:)``), null without one.
    public static func value(_ windows: [Window], index: StringIndex?) -> OracleValue {
        ["windows": .array(windows.map { window -> OracleValue in
            ["window": .string(window.id), "nodes": .array(window.nodes.map { node -> OracleValue in
                [
                    "role": .string(node.role),
                    "labelKey": index?.labelKey(of: node).map(OracleValue.string) ?? .null,
                    "enabled": .bool(node.enabled),
                    "focused": .bool(node.focused),
                    "depth": OracleValue(node.depth),
                ]
            })]
        })]
    }
}

/// The string index of one facet list: the tables do not change while the app runs.
private actor IndexCache {
    private let load: @Sendable () async throws(OracleFacetError) -> OracleAccessibilityFacet.StringIndex
    private var loaded: OracleAccessibilityFacet.StringIndex?

    init(load: @escaping @Sendable () async throws(OracleFacetError) -> OracleAccessibilityFacet.StringIndex) {
        self.load = load
    }

    func index() async throws(OracleFacetError) -> OracleAccessibilityFacet.StringIndex {
        if let loaded { return loaded }
        let index = try await load()
        loaded = index
        return index
    }
}
#endif
