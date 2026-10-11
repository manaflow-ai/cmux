public import Foundation

/// What an applied operation changed, for the views and the stores.
public nonisolated struct BookmarkChange: Sendable, Equatable {
    /// Nodes created (imports list every node, parents first).
    public var created: [String] = []
    public var updated: [String] = []
    public var moved: [String] = []
    public var deleted: [String] = []

    public var isEmpty: Bool { created.isEmpty && updated.isEmpty && moved.isEmpty && deleted.isEmpty }
}

extension BookmarkTree {
    /// Applies `operation` or throws without changing the tree. `makeID`
    /// mints ids for import drafts (tests pass a counter).
    @discardableResult
    public mutating func apply(_ operation: BookmarkOperation, makeID: () -> String = BookmarkID.make,
                               now: Date = Date()) throws -> BookmarkChange {
        var change = BookmarkChange()
        switch operation {
        case .create(let node, let index):
            if nodes[node.id] != nil { return change }
            try validateNew(node, extra: 1)
            insert(node, at: index)
            change.created = [node.id]
        case .update(let id, let title, let url, let favicon, let lastUsed):
            guard var node = nodes[id] else { throw BookmarkError.notFound(id) }
            if let title { node.title = try Self.checkedTitle(title) }
            if let url {
                guard !node.isFolder else { throw BookmarkError.invalidKind }
                guard BookmarkURL.isValid(url) else { throw BookmarkError.invalidURL }
                node.url = url
            }
            switch favicon {
            case .unchanged: break
            case .set(let value): node.faviconKey = value
            case .clear: node.faviconKey = nil
            }
            switch lastUsed {
            case .unchanged: break
            case .set(let value): node.lastUsed = value
            case .clear: node.lastUsed = nil
            }
            guard node != nodes[id] else { return change }
            replace(node)
            change.updated = [id]
        case .move(let id, let parent, let index):
            guard var node = nodes[id] else { throw BookmarkError.notFound(id) }
            guard isContainer(parent) else { throw BookmarkError.invalidParent(parent) }
            if node.isFolder, isDescendant(parent, of: id) { throw BookmarkError.cycle }
            if node.isFolder, let base = BookmarkRoot.isRoot(parent) ? 0 : depth(of: parent),
               base + height(of: id) > BookmarkLimits.depth { throw BookmarkError.tooDeep }
            let oldParent = node.parent
            let oldIndex = self.index(of: id)
            detach(id)
            node.parent = parent
            let target = min(max(index, 0), childIDs[parent]?.count ?? 0)
            insert(node, at: target)
            guard oldParent != parent || oldIndex != target else { return change }
            change.moved = [id]
        case .delete(let id):
            guard nodes[id] != nil else { throw BookmarkError.notFound(id) }
            change.deleted = removeSubtree(id)
        case .importDrafts(let parent, let index, let sourceKey, let replace, let drafts):
            change = try importDrafts(parent: parent, index: index, sourceKey: sourceKey, replacing: replace, drafts: drafts,
                                      makeID: makeID, now: now)
        }
        return change
    }

    private mutating func importDrafts(parent: String, index: Int?, sourceKey: String?, replacing: Bool, drafts: [BookmarkDraft],
                                       makeID: () -> String, now: Date) throws -> BookmarkChange {
        var change = BookmarkChange()
        let total = drafts.reduce(0) { $0 + $1.count }
        if replacing, let sourceKey, let existing = folder(sourceKey: sourceKey), let first = drafts.first {
            let removed = subtree(existing.id).count - 1
            guard nodes.count - removed + total - 1 <= BookmarkLimits.nodesPerProfile else { throw BookmarkError.tooLarge }
            try validate(first.children, depth: (depth(of: existing.id) ?? 1) + 1)
            try validate(Array(drafts.dropFirst()), depth: depth(of: existing.id) ?? 1)
            for child in childIDs[existing.id] ?? [] { change.deleted += removeSubtree(child) }
            var folder = existing
            folder.title = try Self.checkedTitle(first.title)
            replace(folder)
            change.updated = [existing.id]
            for (offset, draft) in first.children.enumerated() {
                change.created += insertDraft(draft, parent: existing.id, index: offset, sourceKey: nil, makeID: makeID, now: now)
            }
            // Further drafts go right after the folder, untagged (the daemon's rule).
            let after = (self.index(of: existing.id) ?? 0) + 1
            for (offset, draft) in drafts.dropFirst().enumerated() {
                change.created += insertDraft(draft, parent: existing.parent, index: after + offset, sourceKey: nil, makeID: makeID, now: now)
            }
            return change
        }
        guard isContainer(parent) else { throw BookmarkError.invalidParent(parent) }
        guard nodes.count + total <= BookmarkLimits.nodesPerProfile else { throw BookmarkError.tooLarge }
        try validate(drafts, depth: (BookmarkRoot.isRoot(parent) ? 0 : depth(of: parent) ?? 0) + 1)
        let start = min(max(index ?? childIDs[parent]?.count ?? 0, 0), childIDs[parent]?.count ?? 0)
        for (offset, draft) in drafts.enumerated() {
            let tag = draft.kind == .folder && offset == 0 ? sourceKey : nil
            change.created += insertDraft(draft, parent: parent, index: start + offset, sourceKey: tag, makeID: makeID, now: now)
        }
        return change
    }

    private mutating func insertDraft(_ draft: BookmarkDraft, parent: String, index: Int, sourceKey: String?, makeID: () -> String,
                                      now: Date) -> [String] {
        let node = BookmarkNode(id: makeID(), parent: parent, kind: draft.kind, title: draft.title,
                                url: draft.kind == .url ? draft.url : nil,
                                faviconKey: draft.url.flatMap(BookmarkURL.faviconKey(for:)),
                                sourceKey: sourceKey, created: draft.created ?? now)
        insert(node, at: index)
        var created = [node.id]
        for (offset, child) in draft.children.enumerated() where draft.kind == .folder {
            created += insertDraft(child, parent: node.id, index: offset, sourceKey: nil, makeID: makeID, now: now)
        }
        return created
    }

    private func validate(_ drafts: [BookmarkDraft], depth: Int) throws {
        guard depth <= BookmarkLimits.depth || drafts.isEmpty else { throw BookmarkError.tooDeep }
        for draft in drafts {
            _ = try Self.checkedTitle(draft.title)
            switch draft.kind {
            case .url:
                guard let url = draft.url, BookmarkURL.isValid(url), draft.children.isEmpty else { throw BookmarkError.invalidURL }
            case .folder:
                try validate(draft.children, depth: depth + 1)
            }
        }
    }

    private func validateNew(_ node: BookmarkNode, extra: Int) throws {
        guard isContainer(node.parent) else { throw BookmarkError.invalidParent(node.parent) }
        guard nodes.count + extra <= BookmarkLimits.nodesPerProfile else { throw BookmarkError.tooLarge }
        _ = try Self.checkedTitle(node.title)
        switch node.kind {
        case .url:
            guard let url = node.url, BookmarkURL.isValid(url) else { throw BookmarkError.invalidURL }
        case .folder:
            guard node.url == nil else { throw BookmarkError.invalidKind }
        }
        let parentDepth = BookmarkRoot.isRoot(node.parent) ? 0 : depth(of: node.parent) ?? 0
        guard parentDepth + 1 <= BookmarkLimits.depth else { throw BookmarkError.tooDeep }
    }

    /// Levels in `id`'s subtree, itself included.
    private func height(of id: String) -> Int {
        1 + ((childIDs[id] ?? []).map { height(of: $0) }.max() ?? 0)
    }

    static func checkedTitle(_ title: String) throws -> String {
        guard title.utf8.count <= BookmarkLimits.titleBytes else { throw BookmarkError.tooLarge }
        return title
    }
}
