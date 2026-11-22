public import Foundation

/// One browser profile's bookmarks: nodes by id and each parent's ordered
/// children. A value type, so the App can apply an operation optimistically
/// and the file store can save the result. Every rule of bookmarks.md
/// section 1 is enforced in `apply`.
public nonisolated struct BookmarkTree: Sendable, Equatable {
    public private(set) var nodes: [String: BookmarkNode] = [:]
    /// Parent id (root raw value or folder id) to ordered child ids.
    public private(set) var childIDs: [String: [String]] = [:]
    /// `BookmarkURL.key` of every `url` node, with how many nodes hold it
    /// (the omnibar star asks on every navigation).
    private var urlKeys: [String: Int] = [:]

    public init() {}

    /// A tree from nodes listed in sibling order (each parent's children in
    /// the order they appear). Nodes whose parent is unknown go to Other
    /// Bookmarks, so nothing a store returns is ever lost.
    public init(ordered: [BookmarkNode]) {
        let known = Set(ordered.lazy.filter(\.isFolder).map(\.id))
        for var node in ordered where nodes[node.id] == nil {
            if !BookmarkRoot.isRoot(node.parent), !known.contains(node.parent) || node.parent == node.id { node.parent = BookmarkRoot.other.rawValue }
            nodes[node.id] = node
            childIDs[node.parent, default: []].append(node.id)
        }
        // A parent cycle in stored data (never written by `apply`) would make
        // nodes unreachable: break it by moving the looping folder to Other.
        for id in Array(nodes.keys) where depth(of: id) == nil {
            guard var node = nodes[id] else { continue }
            childIDs[node.parent]?.removeAll { $0 == id }
            node.parent = BookmarkRoot.other.rawValue
            nodes[id] = node
            childIDs[node.parent, default: []].append(id)
        }
        for node in nodes.values { tally(node, by: 1) }
    }

    // MARK: Reading

    public var count: Int { nodes.count }
    public var isEmpty: Bool { nodes.isEmpty }

    public func node(_ id: String) -> BookmarkNode? { nodes[id] }

    public func children(of parent: String) -> [BookmarkNode] {
        (childIDs[parent] ?? []).compactMap { nodes[$0] }
    }

    public func index(of id: String) -> Int? {
        guard let node = nodes[id] else { return nil }
        return childIDs[node.parent]?.firstIndex(of: id)
    }

    /// Depth-first preorder: the bar's subtree, then Other Bookmarks'. The
    /// order `init(ordered:)` reads back and the file store writes.
    public var ordered: [BookmarkNode] {
        var result: [BookmarkNode] = []
        result.reserveCapacity(nodes.count)
        func visit(_ parent: String) {
            for id in childIDs[parent] ?? [] {
                guard let node = nodes[id] else { continue }
                result.append(node)
                if node.isFolder { visit(id) }
            }
        }
        for root in BookmarkRoot.allCases { visit(root.rawValue) }
        return result
    }

    /// Every `url` node in tree order.
    public var bookmarks: [BookmarkNode] { ordered.filter { !$0.isFolder } }

    /// `url` nodes whose URL is the same page as `url`.
    public func bookmarks(for url: URL) -> [BookmarkNode] {
        let key = BookmarkURL.key(url)
        return bookmarks.filter { $0.url.map(BookmarkURL.key) == key }
    }

    public func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return urlKeys[BookmarkURL.key(url), default: 0] > 0
    }

    /// Whether `id` is `ancestor` or below it.
    public func isDescendant(_ id: String, of ancestor: String) -> Bool {
        var current: String? = id
        var steps = 0
        while let value = current, steps <= nodes.count {
            if value == ancestor { return true }
            current = nodes[value]?.parent
            steps += 1
        }
        return false
    }

    /// Folder depth below its root (top-level nodes are 1), nil on a cycle.
    public func depth(of id: String) -> Int? {
        var current = id
        var depth = 0
        while let node = nodes[current] {
            depth += 1
            if depth > nodes.count { return nil }
            current = node.parent
        }
        return BookmarkRoot.isRoot(current) ? depth : nil
    }

    /// Titles from the root to `id`'s parent, for "Bookmarks Bar › Work".
    public func folderPath(of id: String) -> [String] {
        var path: [String] = []
        var current = nodes[id]?.parent
        while let value = current, let folder = nodes[value] {
            path.insert(folder.displayTitle, at: 0)
            current = folder.parent
        }
        if let root = current.flatMap(BookmarkRoot.init(rawValue:)) { path.insert(root.rawValue, at: 0) }
        return path
    }

    /// The root (`bar` or `other`) that holds `id`.
    public func root(of id: String) -> BookmarkRoot? {
        var current = id
        var steps = 0
        while let node = nodes[current], steps <= nodes.count {
            current = node.parent
            steps += 1
        }
        return BookmarkRoot(rawValue: current)
    }

    /// `id` and every node below it, parents first.
    public func subtree(_ id: String) -> [String] {
        var result = [id]
        var index = 0
        while index < result.count {
            result += childIDs[result[index]] ?? []
            index += 1
        }
        return result
    }

    /// `id` and its subtree as drafts (title, URL, created date, order), to
    /// put a folder back as it was (undo of an import that replaced it).
    public func draft(of id: String) -> BookmarkDraft? {
        guard let node = nodes[id] else { return nil }
        return draft(node, depth: 0)
    }

    private func draft(_ node: BookmarkNode, depth: Int) -> BookmarkDraft {
        let children = node.isFolder && depth < 64 ? self.children(of: node.id).map { draft($0, depth: depth + 1) } : []
        return BookmarkDraft(kind: node.kind, title: node.title, url: node.url, created: node.created, children: children)
    }

    /// The folder created by an import of `sourceKey`, if any.
    public func folder(sourceKey: String) -> BookmarkNode? {
        ordered.first { $0.isFolder && $0.sourceKey == sourceKey }
    }

    /// Whether `parent` can hold children: a root or a folder of this tree.
    public func isContainer(_ parent: String) -> Bool {
        BookmarkRoot.isRoot(parent) || nodes[parent]?.isFolder == true
    }

    // MARK: Internal mutation (BookmarkTree+Apply)

    private mutating func tally(_ node: BookmarkNode?, by delta: Int) {
        guard let node, !node.isFolder, let url = node.url else { return }
        let key = BookmarkURL.key(url)
        let value = urlKeys[key, default: 0] + delta
        urlKeys[key] = value > 0 ? value : nil
    }

    mutating func insert(_ node: BookmarkNode, at index: Int?) {
        tally(nodes[node.id], by: -1)
        tally(node, by: 1)
        nodes[node.id] = node
        var siblings = childIDs[node.parent] ?? []
        let position = min(max(index ?? siblings.count, 0), siblings.count)
        siblings.insert(node.id, at: position)
        childIDs[node.parent] = siblings
    }

    mutating func detach(_ id: String) {
        guard let node = nodes[id] else { return }
        childIDs[node.parent]?.removeAll { $0 == id }
    }

    mutating func replace(_ node: BookmarkNode) {
        tally(nodes[node.id], by: -1)
        tally(node, by: 1)
        nodes[node.id] = node
    }

    mutating func removeSubtree(_ id: String) -> [String] {
        let removed = subtree(id)
        detach(id)
        for value in removed {
            tally(nodes[value], by: -1)
            nodes[value] = nil
            childIDs[value] = nil
        }
        return removed
    }
}
