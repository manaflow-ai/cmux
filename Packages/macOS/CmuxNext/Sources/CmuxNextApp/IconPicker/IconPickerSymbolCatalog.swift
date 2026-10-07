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
/// The bundled snapshot (Resources/IconPickerSymbols.txt) is the fallback: a missing or
/// unreadable system catalog leaves its names, sorted, with no keywords or categories, so the
/// tab is never empty.
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
    static var bundledSnapshot: URL? { Bundle.module.url(forResource: "IconPickerSymbols", withExtension: "txt") }

    /// The catalog, read off the main actor (five plist reads, about 1 MB).
    @concurrent static func load(resources: URL = systemResources, snapshot: URL? = bundledSnapshot) async -> IconPickerSymbolCatalog {
        // concurrency-allow: @concurrent, so the file reads in read(resources:snapshot:) never run on the main actor
        read(resources: resources, snapshot: snapshot)
    }

    /// The catalog from the plists in `resources` plus the names in `snapshot` (one per line).
    /// Synchronous file reads: call it off the main actor (``load(resources:snapshot:)``).
    static func read(resources: URL, snapshot: URL?) -> IconPickerSymbolCatalog {
        // Red stub: the old behavior (sorted names, nothing else).
        var available = Set(lines(snapshot).filter(IconValue.isSymbolName))
        if let symbols = (plist(resources, "name_availability") as? [String: Any])?["symbols"] as? [String: Any] {
            available.formUnion(symbols.keys.filter(IconValue.isSymbolName))
        }
        let names = available.sorted()
        return IconPickerSymbolCatalog(names: names, keywords: names.map { _ in "" }, categories: [])
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
        ["symbols": .array(names.map(JSONValue.string))]
    }

    private static func plist(_ resources: URL, _ name: String) -> Any? {
        // concurrency-allow: called only from read(resources:snapshot:), which load(resources:snapshot:) runs off the main actor
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("\(name).plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    private static func lines(_ url: URL?) -> [String] {
        // concurrency-allow: called only from read(resources:snapshot:), which load(resources:snapshot:) runs off the main actor
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
