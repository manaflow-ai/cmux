public import Foundation

/// A field edit: keep, set, or clear.
public nonisolated enum BookmarkFieldChange<Value: Sendable & Hashable>: Sendable, Hashable {
    case unchanged
    case set(Value)
    case clear
}

/// A node to create inside an import (HTML, onboarding): ids are minted
/// when it is applied.
public nonisolated struct BookmarkDraft: Sendable, Hashable {
    public var kind: BookmarkNode.Kind
    public var title: String
    public var url: URL?
    public var created: Date?
    public var children: [BookmarkDraft]

    public init(kind: BookmarkNode.Kind, title: String, url: URL? = nil, created: Date? = nil, children: [BookmarkDraft] = []) {
        self.kind = kind
        self.title = title
        self.url = url
        self.created = created
        self.children = children
    }

    public static func folder(_ title: String, created: Date? = nil, _ children: [BookmarkDraft]) -> BookmarkDraft {
        BookmarkDraft(kind: .folder, title: title, created: created, children: children)
    }

    public static func bookmark(_ title: String, _ url: URL, created: Date? = nil) -> BookmarkDraft {
        BookmarkDraft(kind: .url, title: title, url: url, created: created)
    }

    /// Nodes in this draft, itself included.
    public var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
}

/// One mutation of a profile's tree. The same value is applied to the local
/// tree (file store, optimistic view) and sent to the daemon
/// (`bookmarks-v1`), so both sides follow one rule set.
public nonisolated enum BookmarkOperation: Sendable, Hashable {
    /// Insert `node` under `node.parent` at `index` (nil appends).
    case create(BookmarkNode, index: Int?)
    case update(id: String, title: String? = nil, url: URL? = nil, faviconKey: BookmarkFieldChange<String> = .unchanged,
                lastUsed: BookmarkFieldChange<Date> = .unchanged)
    /// `index` is the final position among the destination's children.
    case move(id: String, parent: String, index: Int)
    /// Removes the node and, for a folder, its subtree.
    case delete(id: String)
    /// Inserts drafts under `parent`. With `sourceKey` and `replace`, the
    /// folder carrying `sourceKey` keeps its id and position and gets the
    /// first draft's title and children (created at `parent`/`index` when
    /// missing; the created folder carries `sourceKey`).
    case importDrafts(parent: String, index: Int?, sourceKey: String?, replace: Bool, drafts: [BookmarkDraft])
}
