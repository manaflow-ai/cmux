public import Foundation
import CmuxNextWindowRules

/// What an applied operation changed: nothing, or something.
public nonisolated struct BookmarkChange: Sendable, Equatable {
    public var isEmpty: Bool

    public init(isEmpty: Bool) {
        self.isEmpty = isEmpty
    }
}

extension BookmarkTree {
    /// Applies `operation` or throws without changing the tree. Every rule (validation, limits,
    /// cycles, imports) is cmux-bookmarks-core's, the daemon's own, asked over the app FFI
    /// (`bookmarks_apply`): this only maps the operation onto the wire and the answer back.
    @discardableResult
    public mutating func apply(_ operation: BookmarkOperation, now: Date = Date()) throws -> BookmarkChange {
        let (tree, results) = try Self.ask(ordered, [operation], now: now)
        guard let result = results.first else { throw BookmarkError.unavailable }
        let change = try result.get()
        self = tree
        return change
    }

    /// Applies `operations` in order in one `bookmarks_apply` call (one tree round trip
    /// however many there are), with one result per operation. A refused operation changes
    /// nothing and the rest still apply, as the daemon does with each op it is sent. Throws
    /// only when the FFI does not answer, leaving the tree unchanged.
    @discardableResult
    public mutating func apply(_ operations: [BookmarkOperation],
                               now: Date = Date()) throws -> [Result<BookmarkChange, BookmarkError>] {
        guard !operations.isEmpty else { return [] }
        let (tree, results) = try Self.ask(ordered, operations, now: now)
        self = tree
        return results
    }

    private static func ask(_ tree: [BookmarkNode], _ operations: [BookmarkOperation],
                            now: Date) throws -> (BookmarkTree, [Result<BookmarkChange, BookmarkError>]) {
        let request = BookmarkApplyRequest(tree: tree, ops: operations.map(BookmarkOpWire.init), nowMs: BookmarkTime.ms(now),
                                           seed: UInt64.random(in: 0..<(1 << 53)))
        guard let reply = WindowRules().call("bookmarks_apply", request, as: BookmarkApplyReply.self),
              reply.results.count == operations.count else { throw BookmarkError.unavailable }
        let results = reply.results.map { result -> Result<BookmarkChange, BookmarkError> in
            if let reason = result.reason { return .failure(BookmarkError(reason: reason, message: result.message ?? "")) }
            return .success(BookmarkChange(isEmpty: result.changed != true))
        }
        return (BookmarkTree(ordered: reply.tree), results)
    }
}

extension BookmarkOperation {
    /// The operations of a batch to send to the daemon: each applied one that changed
    /// something, and every applied import (the daemon mints its own ids for it).
    public static func sent(_ operations: [BookmarkOperation],
                            _ results: [Result<BookmarkChange, BookmarkError>]) -> [BookmarkOperation] {
        zip(operations, results).compactMap { operation, result in
            guard let change = try? result.get() else { return nil }
            if case .importDrafts = operation { return operation }
            return change.isEmpty ? nil : operation
        }
    }
}

private nonisolated struct BookmarkApplyRequest: Encodable {
    var browserProfileId = "default"
    var tree: [BookmarkNode]
    var ops: [BookmarkOpWire]
    var nowMs: Int64
    var seed: UInt64

    private enum CodingKeys: String, CodingKey {
        case browserProfileId = "browser_profile_id", tree, ops, nowMs = "now_ms", seed
    }
}

private nonisolated struct BookmarkApplyReply: Decodable {
    struct Result: Decodable {
        var changed: Bool?
        var reason: String?
        var message: String?
    }

    var tree: [BookmarkNode]
    var results: [Result]
}

/// One operation in the daemon's op JSON (`{"op": "create", ...}`).
private nonisolated struct BookmarkOpWire: Encodable {
    let operation: BookmarkOperation

    init(_ operation: BookmarkOperation) {
        self.operation = operation
    }

    private enum Keys: String, CodingKey {
        case op, bookmark, parent, index, kind, title, url, id, replace, nodes, children
        case profile = "browser_profile_id", favicon = "favicon_key", source = "source_key"
        case created = "created_ms", lastUsed = "last_used_ms", icon
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch operation {
        case .create(let node, let index):
            try c.encode("create", forKey: .op)
            try c.encode("default", forKey: .profile)
            try c.encode(node.id, forKey: .id)
            try c.encode(node.parent, forKey: .parent)
            try c.encodeIfPresent(index, forKey: .index)
            try c.encode(node.kind, forKey: .kind)
            try c.encode(node.title, forKey: .title)
            try c.encodeIfPresent(node.url?.absoluteString, forKey: .url)
            try c.encodeIfPresent(node.faviconKey, forKey: .favicon)
            try c.encodeIfPresent(node.sourceKey, forKey: .source)
            try c.encode(BookmarkTime.ms(node.created), forKey: .created)
        case .update(let id, let title, let url, let favicon, let lastUsed, let icon):
            try c.encode("update", forKey: .op)
            try c.encode(id, forKey: .bookmark)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encodeIfPresent(url?.absoluteString, forKey: .url)
            try Self.encode(favicon, forKey: .favicon, in: &c)
            switch lastUsed {
            case .unchanged: break
            case .set(let date): try c.encode(BookmarkTime.ms(date), forKey: .lastUsed)
            case .clear: try c.encodeNil(forKey: .lastUsed)
            }
            try Self.encode(icon, forKey: .icon, in: &c)
        case .move(let id, let parent, let index):
            try c.encode("move", forKey: .op)
            try c.encode(id, forKey: .bookmark)
            try c.encode(parent, forKey: .parent)
            try c.encode(index, forKey: .index)
        case .delete(let id):
            try c.encode("delete", forKey: .op)
            try c.encode(id, forKey: .bookmark)
        case .importDrafts(let parent, let index, let sourceKey, let replace, let drafts):
            try c.encode("import", forKey: .op)
            try c.encode("default", forKey: .profile)
            try c.encode(parent, forKey: .parent)
            try c.encodeIfPresent(index, forKey: .index)
            try c.encodeIfPresent(sourceKey, forKey: .source)
            try c.encode(replace, forKey: .replace)
            try c.encode(drafts.map(DraftWire.init), forKey: .nodes)
        }
    }

    /// An absent field is unchanged; JSON null clears.
    private static func encode<Value: Encodable>(_ change: BookmarkFieldChange<Value>, forKey key: Keys,
                                                 in container: inout KeyedEncodingContainer<Keys>) throws {
        switch change {
        case .unchanged: break
        case .set(let value): try container.encode(value, forKey: key)
        case .clear: try container.encodeNil(forKey: key)
        }
    }

    private struct DraftWire: Encodable {
        let draft: BookmarkDraft

        init(_ draft: BookmarkDraft) {
            self.draft = draft
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(draft.kind, forKey: .kind)
            try c.encode(draft.title, forKey: .title)
            try c.encodeIfPresent(draft.url?.absoluteString, forKey: .url)
            try c.encodeIfPresent(draft.created.map(BookmarkTime.ms), forKey: .created)
            if !draft.children.isEmpty { try c.encode(draft.children.map(DraftWire.init), forKey: .children) }
        }
    }
}
