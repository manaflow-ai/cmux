import CmuxNextDesign
import CmuxNextSettings
import Foundation

/// The SF Symbols catalog of the running system for the icon picker's Symbols tab
/// (ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS): the names this Mac draws in the system's order,
/// each name's search keywords and the system categories, read from CoreGlyphs.bundle:
/// `name_availability.plist` (names), `symbol_order.plist` (order), `symbol_search.plist`
/// (name -> keywords), `symbol_categories.plist` (name -> category keys) and `categories.plist`
/// ([{key, icon}]). The search and category tables list base names only (`heart`, not
/// `heart.fill`), so a name takes the entry of its nearest dotted prefix.
///
/// The catalog is read at run time from the user's own system only. The app ships no copy of
/// Apple's symbol names, categories or keywords (SF Symbols license). Without
/// `name_availability.plist` the names come from `symbol_order.plist`; with neither the
/// catalog is empty and the page shows its empty state.
nonisolated struct IconPickerSymbolCatalog: Equatable, Sendable {
    nonisolated struct Category: Equatable, Sendable {
        /// The system's key (`objectsandtools`); the page localizes the title.
        let key: String
        /// The SF Symbol that stands for the category (the page's jump bar).
        let icon: String
        /// Indices into ``IconPickerSymbolCatalog/names``, in name order.
        let members: [Int]
    }

    var names: [String]
    /// Aligned with ``names``: the keywords joined by spaces ("" for none).
    var keywords: [String]
    var categories: [Category]

    static let systemResources = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources",
                                     isDirectory: true)
    /// The catalog, read off the main actor (five plist reads, about 1 MB).
    @concurrent static func load(resources: URL = systemResources) async -> IconPickerSymbolCatalog {
        // concurrency-allow: @concurrent, so the file reads in read(resources:) never run on the main actor
        read(resources: resources)
    }

    /// The catalog from the plists in `resources`.
    /// Synchronous file reads: call it off the main actor (``load(resources:)``).
    static func read(resources: URL) -> IconPickerSymbolCatalog {
        let order = plist(resources, "symbol_order") as? [String] ?? []
        let available: Set<String>
        if let symbols = (plist(resources, "name_availability") as? [String: Any])?["symbols"] as? [String: Any] {
            available = Set(symbols.keys.filter(IconValue.isSymbolName))
        } else {
            available = Set(order.filter(IconValue.isSymbolName))
        }
        var names: [String] = []
        var placed = Set<String>()
        for name in order where available.contains(name) {
            if placed.insert(name).inserted { names.append(name) }
        }
        names += available.subtracting(placed).sorted()

        let search = plist(resources, "symbol_search") as? [String: [String]] ?? [:]
        let keywords = names.map { lookup($0, in: search)?.joined(separator: " ") ?? "" }

        let memberships = plist(resources, "symbol_categories") as? [String: [String]] ?? [:]
        var members: [String: [Int]] = [:]
        for (index, name) in names.enumerated() {
            for key in lookup(name, in: memberships) ?? [] {
                members[key, default: []].append(index)
            }
        }
        let categories = (plist(resources, "categories") as? [[String: Any]] ?? []).compactMap { entry -> Category? in
            guard let key = entry["key"] as? String, let icon = entry["icon"] as? String, IconValue.isSymbolName(icon) else { return nil }
            return Category(key: key, icon: icon, members: members[key] ?? [])
        }
        return IconPickerSymbolCatalog(names: names, keywords: keywords, categories: categories)
    }

    /// `name`'s entry in `table`, else the entry of its nearest dotted prefix
    /// (`heart.fill` -> `heart`), else nil.
    static func lookup<Value>(_ name: String, in table: [String: Value]) -> Value? {
        var parts = name.split(separator: ".")
        while !parts.isEmpty {
            if let value = table[parts.joined(separator: ".")] { return value }
            parts.removeLast()
        }
        return nil
    }

    /// The session event's catalog members: `symbols`, `symbolKeywords`, `symbolCategories`
    /// (webviews/src/pages/icon-picker/host.ts PickerSession).
    var eventMembers: [String: JSONValue] {
        [
            "symbols": .array(names.map(JSONValue.string)),
            "symbolKeywords": .array(keywords.map(JSONValue.string)),
            "symbolCategories": .array(categories.map { category in
                .object([
                    "key": .string(category.key),
                    "icon": .string(category.icon),
                    "members": .array(category.members.map { JSONValue($0) }),
                ])
            }),
        ]
    }

    private static func plist(_ resources: URL, _ name: String) -> Any? {
        // concurrency-allow: called only from read(resources:), which load(resources:) runs off the main actor
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("\(name).plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }
}
