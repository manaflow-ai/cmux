import Foundation

/// Every SF Symbol this iPhone draws, for Set Icon…'s picker, as the Mac's icon picker reads its
/// own (`IconPickerSymbolCatalog`): the names from the system's CoreGlyphs bundle
/// (`name_availability.plist`, else `symbol_order.plist`), in the system's order
/// (`symbol_order.plist`, then the rest by name), each with its search keywords
/// (`symbol_search.plist`, by the nearest dotted prefix). Read at run time from the phone's own
/// system only: the app ships no copy of Apple's symbol names or keywords (SF Symbols license).
/// Without those files the catalog is empty and the picker says so.
public struct WorkspaceSymbolCatalog: Equatable, Sendable {
    public var names: [String]
    /// Aligned with `names`: the keywords joined by spaces ("" for none).
    public var keywords: [String]

    public init(names: [String], keywords: [String]) {
        self.names = names
        self.keywords = keywords.count == names.count ? keywords : Array(repeating: "", count: names.count)
    }

    public static let empty = WorkspaceSymbolCatalog(names: [], keywords: [])

    /// The CoreGlyphs bundles to try: the simulator runtime's, then the system's.
    public static func systemBundles(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let path = "System/Library/CoreServices/CoreGlyphs.bundle"
        var urls: [URL] = []
        if let root = environment["IPHONE_SIMULATOR_ROOT"], !root.isEmpty {
            urls.append(URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(path, isDirectory: true))
        }
        urls.append(URL(fileURLWithPath: "/" + path, isDirectory: true))
        return urls
    }

    /// The first readable catalog of `bundles`. Synchronous file reads (about 1 MB): call it off
    /// the main actor (`load()`).
    public static func read(bundles: [URL] = systemBundles()) -> WorkspaceSymbolCatalog {
        for url in bundles {
            guard let bundle = Bundle(url: url) else { continue }
            let catalog = read { name in bundle.url(forResource: name, withExtension: "plist") }
            if !catalog.names.isEmpty { return catalog }
        }
        return .empty
    }

    /// The catalog off the main actor.
    public static func load() async -> WorkspaceSymbolCatalog {
        await Task.detached(priority: .userInitiated) { read() }.value
    }

    /// The catalog from the plists `file` finds by name.
    static func read(_ file: (String) -> URL?) -> WorkspaceSymbolCatalog {
        func plist(_ name: String) -> Any? {
            guard let url = file(name), let data = try? Data(contentsOf: url) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
        let order = plist("symbol_order") as? [String] ?? []
        let available: Set<String>
        if let symbols = (plist("name_availability") as? [String: Any])?["symbols"] as? [String: Any] {
            available = Set(symbols.keys.filter(WorkspaceIcon.isSymbolName))
        } else {
            available = Set(order.filter(WorkspaceIcon.isSymbolName))
        }
        var names: [String] = []
        var placed = Set<String>()
        for name in order where available.contains(name) && placed.insert(name).inserted {
            names.append(name)
        }
        names += available.subtracting(placed).sorted()
        let search = plist("symbol_search") as? [String: [String]] ?? [:]
        return WorkspaceSymbolCatalog(names: names, keywords: names.map { lookup($0, in: search)?.joined(separator: " ") ?? "" })
    }

    /// `name`'s entry in `table`, else the entry of its nearest dotted prefix (`heart.fill` -> `heart`).
    static func lookup<Value>(_ name: String, in table: [String: Value]) -> Value? {
        var parts = name.split(separator: ".")
        while !parts.isEmpty {
            if let value = table[parts.joined(separator: ".")] { return value }
            parts.removeLast()
        }
        return nil
    }

    /// The names that match `query`: every word of it in the name or its keywords, names that
    /// start with the query first. Empty query: every name.
    public func search(_ query: String) -> [String] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return names }
        var prefix: [String] = []
        var rest: [String] = []
        for (index, name) in names.enumerated() {
            let haystack = name + " " + keywords[index].lowercased()
            guard words.allSatisfy({ haystack.contains($0) }) else { continue }
            if name.hasPrefix(words[0]) { prefix.append(name) } else { rest.append(name) }
        }
        return prefix + rest
    }
}

extension WorkspaceIcon {
    /// An SF Symbol name as the Mac's daemon stores it (`IconValue.isSymbolName`): lowercase words
    /// of letters and digits joined by single dots, at most 128 bytes.
    public static func isSymbolName(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 128, !text.hasPrefix("."), !text.hasSuffix("."), !text.contains("..") else { return false }
        return text.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E }
    }
}
