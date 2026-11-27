/// A person's arrangement of one right-click menu (Settings > Menus, cmux.json
/// `contextMenus.layouts.<menu>`), applied over the generated menu (``ContextMenuCatalog``):
/// the whole menu as a tree, so any row can sit anywhere, at any depth.
///
/// - ``items`` is the top level in order: a row by key (an action's ID), a separator, or a
///   submenu with its own rows. A submenu is one the app makes (`folder:<name>`, More is
///   `folder:more`) or one the person made (`group:<id>`, with a title); either holds any rows,
///   other submenus included.
/// - ``hidden`` rows keep their place in ``items`` and are left out of the menu; a hidden submenu
///   takes what it holds with it. Showing one again puts it back where it was.
///
/// A row the layout does not name keeps its generated place: inside the submenu the app makes it
/// in, wherever the person put that submenu, after the row it follows there (an action the app
/// adds later shows up where the app puts it). A named row the app no longer places is dropped;
/// a submenu the app no longer makes leaves its rows where it was. A row submenu (an action that
/// opens one, such as Move to Group ▸) and a choices row move whole.
public nonisolated struct ContextMenuLayout: Sendable, Hashable {
    public static let separator = "-"
    public static let moreKey = folderKey(.more)
    /// The key prefix of a submenu the person made.
    public static let groupPrefix = "group:"

    /// One entry of the tree.
    public indirect enum Node: Sendable, Hashable {
        case item(String)
        case separator
        /// A submenu: the app's (`folder:<name>`, `title` nil) or the person's (`group:<id>`).
        case folder(key: String, title: String?, items: [Node])

        public var key: String? {
            switch self {
            case .item(let key), .folder(let key, _, _): key
            case .separator: nil
            }
        }
    }

    public var items: [Node]
    public var hidden: [String]

    public init(items: [Node], hidden: [String] = []) {
        self.items = items
        self.hidden = hidden
    }

    public static func folderKey(_ folder: MenuFolder) -> String { "folder:\(folder.rawValue)" }

    public static func isGroup(_ key: String) -> Bool { key.hasPrefix(groupPrefix) }

    /// The key a layout names `entry` by; nil for a separator.
    public static func key(of entry: ContextMenuEntry) -> String? {
        switch entry {
        case .action(let id), .choices(let id), .submenu(let id, _): id.rawValue
        case .folder(let folder, _): folderKey(folder)
        case .group(let group, _): group.key
        case .separator: nil
        }
    }

    /// The generated menu as a layout: every row where the app puts it, nothing hidden.
    public static func generated(_ entries: [ContextMenuEntry]) -> ContextMenuLayout {
        func nodes(_ entries: [ContextMenuEntry]) -> [Node] {
            entries.map { entry in
                switch entry {
                case .separator: .separator
                case .folder(let folder, let children): .folder(key: folderKey(folder), title: nil, items: nodes(children))
                case .group(let group, let children): .folder(key: group.key, title: group.title, items: nodes(children))
                case .action, .choices, .submenu: .item(key(of: entry) ?? "")
                }
            }
        }
        return ContextMenuLayout(items: nodes(entries))
    }

    /// One row a layout can place: a generated entry and the submenu it was generated in (nil for
    /// the top level). A submenu's rows are rows too; a row submenu or choices row moves whole.
    public struct Unit: Sendable, Hashable {
        public let key: String
        public let entry: ContextMenuEntry
        public let home: String?
    }

    /// Every placeable row of `entries`, in menu order, submenus before their rows.
    public static func units(in entries: [ContextMenuEntry]) -> [Unit] {
        var units: [Unit] = []
        var seen: Set<String> = []
        func walk(_ entries: [ContextMenuEntry], home: String?) {
            for entry in entries {
                guard let key = key(of: entry), seen.insert(key).inserted else { continue }
                units.append(Unit(key: key, entry: entry, home: home))
                if case .folder(_, let children) = entry { walk(children, home: key) }
            }
        }
        walk(entries, home: nil)
        return units
    }

    /// Each container's generated entries in order (`-` for a separator), by its key ("" for the
    /// top level): where a row the layout does not name goes.
    static func generatedOrder(_ entries: [ContextMenuEntry]) -> [String: [String]] {
        var order: [String: [String]] = [:]
        func walk(_ entries: [ContextMenuEntry], container: String) {
            order[container] = entries.map { key(of: $0) ?? separator }
            for case .folder(let folder, let children) in entries { walk(children, container: folderKey(folder)) }
        }
        walk(entries, container: "")
        return order
    }

    /// This layout against the generated `entries`: rows the app no longer places dropped, each
    /// named once (hidden ones kept in place), and the generated rows it does not name inserted
    /// where the app puts them. What the Settings editor starts from, and what ``applied(to:)`` draws.
    public func normalized(against entries: [ContextMenuEntry]) -> ContextMenuLayout {
        let units = Self.units(in: entries)
        let known = Set(units.map(\.key))
        let folders = Set(units.compactMap { unit -> String? in if case .folder = unit.entry { unit.key } else { nil } })
        var seen: Set<String> = []
        func clean(_ nodes: [Node]) -> [Node] {
            var result: [Node] = []
            for node in nodes {
                switch node {
                case .separator:
                    result.append(.separator)
                case .item(let key):
                    if known.contains(key), !folders.contains(key), seen.insert(key).inserted { result.append(node) }
                case .folder(let key, let title, let items):
                    if Self.isGroup(key), seen.insert(key).inserted {
                        result.append(.folder(key: key, title: title ?? "", items: clean(items)))
                    } else if folders.contains(key), seen.insert(key).inserted {
                        result.append(.folder(key: key, title: nil, items: clean(items)))
                    } else {
                        // A submenu the app no longer makes, or named twice: its rows stay here.
                        result += clean(items)
                    }
                }
            }
            return result
        }
        var tree = clean(items)
        // Every row stays in the tree, hidden ones too, so a hidden row shows again where it was.
        var hiddenSeen: Set<String> = []
        let hidden = self.hidden.filter { (known.contains($0) || Self.isGroup($0) && seen.contains($0)) && hiddenSeen.insert($0).inserted }
        let order = Self.generatedOrder(entries)
        // Submenus before their rows (`units` is in menu order), so a submenu the layout does not
        // name exists before its rows go into it, and each row brings its section's divider.
        for unit in units where !seen.contains(unit.key) {
            seen.insert(unit.key)
            let node: Node = folders.contains(unit.key) ? .folder(key: unit.key, title: nil, items: []) : .item(unit.key)
            let siblings = order[unit.home ?? ""] ?? []
            guard let at = siblings.firstIndex(of: unit.key) else { continue }
            _ = Self.insert(node, into: unit.home, in: &tree) { keys in Self.insertion(of: at, generated: siblings, in: keys) }
        }
        return ContextMenuLayout(items: tree, hidden: hidden)
    }

    /// Where a generated row goes among a container's keys: the index, and whether it starts or ends
    /// a section of its own there (a divider goes before or after it).
    struct Insertion: Equatable {
        var index: Int
        var dividerBefore = false
        var dividerAfter = false
    }

    /// Inserts `node` into the submenu `container` (nil: the top level) of `tree`, where `position`
    /// picks from that container's keys (`-` for a separator), with the dividers it asks for. False
    /// when the tree has no such submenu.
    @discardableResult
    static func insert(_ node: Node, into container: String?, in tree: inout [Node], at position: ([String]) -> Insertion) -> Bool {
        func place(_ items: inout [Node]) {
            let spot = position(items.map { $0.key ?? separator })
            let at = min(max(0, spot.index), items.count)
            var nodes = [node]
            if spot.dividerBefore, at > 0, items[at - 1] != .separator { nodes.insert(.separator, at: 0) }
            if spot.dividerAfter, at < items.count, items[at] != .separator { nodes.append(.separator) }
            items.insert(contentsOf: nodes, at: at)
        }
        guard let container else {
            place(&tree)
            return true
        }
        for index in tree.indices {
            guard case .folder(let key, let title, var items) = tree[index] else { continue }
            if key == container {
                place(&items)
                tree[index] = .folder(key: key, title: title, items: items)
                return true
            }
            if insert(node, into: container, in: &items, at: position) {
                tree[index] = .folder(key: key, title: title, items: items)
                return true
            }
        }
        return false
    }

    /// Where a generated row (at `index` of its container's generated keys, separators included)
    /// goes among `keys`:
    /// 1. after the row it follows in its generated section, else
    /// 2. before the row that follows it there (a divider before it when the row above is of
    ///    another section), else (its section has no row here yet)
    /// 3. after the run of rows holding the nearest earlier row, as a section of its own, else
    /// 4. before the run of rows holding the nearest later row, as a section of its own, else
    /// 5. at the end (the container holds none of its generated rows: the person's own rows stay first).
    /// A row added to a section stays in it, and a section the app adds keeps its dividers.
    static func insertion(of index: Int, generated: [String], in keys: [String]) -> Insertion {
        let before = generated[..<index], after = generated[(index + 1)...]
        let sectionStart = before.lastIndex(of: separator).map { $0 + 1 } ?? before.startIndex
        let sectionEnd = after.firstIndex(of: separator) ?? after.endIndex
        // The rows of its own generated section: a divider never goes between them, however the
        // person ordered them.
        let section = Set(before[sectionStart...]).union(after[..<sectionEnd])
        if let anchor = before[sectionStart...].last(where: keys.contains), let at = keys.firstIndex(of: anchor) { return Insertion(index: at + 1) }
        // The first of its section here: a divider before it unless the row before is of its section.
        if let next = after[..<sectionEnd].first(where: keys.contains), let at = keys.firstIndex(of: next) {
            let other = at > 0 && keys[at - 1] != separator && !section.contains(keys[at - 1])
            return Insertion(index: at, dividerBefore: other)
        }
        let present = { (key: String) in key != separator && keys.contains(key) }
        // A section of its own: after the run of rows that holds the nearest earlier row (at the
        // next divider, or the end), so it never splits that run.
        if let anchor = before.last(where: present), let at = keys.firstIndex(of: anchor) {
            let runEnd = keys[(at + 1)...].firstIndex(of: separator) ?? keys.endIndex
            return Insertion(index: runEnd, dividerBefore: true)
        }
        // Or before the run that holds the nearest later row (just after the divider before it).
        if let next = after.first(where: present), let at = keys.firstIndex(of: next) {
            let runStart = keys[..<at].lastIndex(of: separator).map { $0 + 1 } ?? keys.startIndex
            return Insertion(index: runStart, dividerAfter: true)
        }
        return Insertion(index: keys.count, dividerBefore: true)
    }

    /// The menu `entries` arranged by this layout (``normalized(against:)`` first). A submenu left
    /// with no rows disappears; runs of separators collapse.
    public func applied(to entries: [ContextMenuEntry]) -> [ContextMenuEntry] {
        let layout = normalized(against: entries)
        let byKey = Dictionary(Self.units(in: entries).map { ($0.key, $0.entry) }, uniquingKeysWith: { first, _ in first })
        let hidden = Set(layout.hidden)
        func render(_ nodes: [Node]) -> [ContextMenuEntry] {
            nodes.compactMap { node -> ContextMenuEntry? in
                // A hidden row leaves the menu; a hidden submenu takes what it holds.
                if let key = node.key, hidden.contains(key) { return nil }
                switch node {
                case .separator:
                    return .separator
                case .item(let key):
                    return byKey[key]
                case .folder(let key, let title, let items):
                    if Self.isGroup(key) { return .group(ContextMenuGroup(key: key, title: title ?? ""), render(items)) }
                    guard case .folder(let folder, _)? = byKey[key] else { return nil }
                    return .folder(folder, render(items))
                }
            }
        }
        return Self.collapsingSeparators(render(layout.items))
    }

    /// Whether this layout draws `entries` as generated.
    public func isGenerated(for entries: [ContextMenuEntry]) -> Bool {
        normalized(against: entries) == Self.generated(entries)
    }

    /// One separator between sections and none at the ends, inside submenus too; a submenu left
    /// with no rows disappears.
    static func collapsingSeparators(_ entries: [ContextMenuEntry]) -> [ContextMenuEntry] {
        var result: [ContextMenuEntry] = []
        for entry in entries {
            switch entry {
            case .separator:
                if let last = result.last, last != .separator { result.append(entry) }
            case .folder(let folder, let children):
                let kept = collapsingSeparators(children)
                if !kept.isEmpty { result.append(.folder(folder, kept)) }
            case .group(let group, let children):
                let kept = collapsingSeparators(children)
                if !kept.isEmpty { result.append(.group(group, kept)) }
            default:
                result.append(entry)
            }
        }
        while case .separator? = result.last { result.removeLast() }
        return result
    }
}

/// A submenu the person made in Settings > Menus: its layout key (`group:<id>`) and title.
public nonisolated struct ContextMenuGroup: Sendable, Hashable {
    public let key: String
    public let title: String

    public init(key: String, title: String) {
        self.key = key
        self.title = title
    }
}
