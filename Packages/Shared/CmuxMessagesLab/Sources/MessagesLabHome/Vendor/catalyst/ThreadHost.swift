import Foundation
import CoreGraphics

// Host options for threads (cmux Home, cx-3cb host-hooks). One switch, `ThreadMode`, on the
// store (`Store.setThreadMode`). `.messages` is the default and keeps macOS Messages' rule
// exactly: a reply stores its thread's root, the thread view shows the root and its replies.
// `.tree` is for a host whose data nests replies (cmux's Channels page and daemon: a reply has a
// `reply_to` parent and a `thread_root`). The host keeps the data and the rules; this file only
// orders the messages the host gave and remembers which branch the thread view shows.

/// How replies nest in a conversation (a host option; standalone MessagesLab never changes it).
enum ThreadMode: String, Equatable {
    /// macOS Messages: one level. A reply's `replyTo` is the thread root; `Message.parent` stays nil.
    case messages
    /// Nested replies. A reply's `replyTo` is still the thread root (so the transcript groups it
    /// with its thread as in `.messages`), and `Message.parent` is the message it answers (nil:
    /// the root itself). The thread view shows the whole tree and can open one branch (drill-in).
    case tree
}

/// Tree order of a thread (`.tree` mode). A thread's members are the messages whose `replyTo` is
/// the root; a member's parent is `parent` when that message is a loaded member, else the root
/// (a parent outside the window, or a reply sent in `.messages` mode, hangs under the root).
/// Siblings keep window order. Pure functions over the loaded window; no host data is invented.
enum ThreadTree {
    /// The parent of `m` inside the thread of `root` (the root's id when its parent is not a member).
    static func parentID(_ m: Message, root: PartRef, members: Set<ID>) -> ID {
        guard let p = m.parent?.messageId, p != m.id, members.contains(p) else { return root.messageId }
        return p
    }

    /// The thread's members (not the root) in window order.
    static func members(of root: PartRef, in messages: [Message]) -> [Message] {
        messages.filter { $0.replyTo == root && $0.id != root.messageId }
    }

    /// Children of every member and of the root, in window order.
    static func children(of root: PartRef, members: [Message]) -> [ID: [Message]] {
        let ids = Set(members.map(\.id))
        var out: [ID: [Message]] = [:]
        for m in members { out[parentID(m, root: root, members: ids), default: []].append(m) }
        return out
    }

    /// `start` and every message under it, depth first, siblings in window order. Members that
    /// a cycle in the host's parents cut off from the root follow in window order (never dropped).
    static func order(from start: Message, root: PartRef, members: [Message]) -> [Message] {
        let kids = children(of: root, members: members)
        var out: [Message] = []
        var seen: Set<ID> = []
        var stack: [Message] = [start]
        while let m = stack.popLast() {
            guard seen.insert(m.id).inserted else { continue }
            out.append(m)
            stack.append(contentsOf: (kids[m.id] ?? []).reversed())
        }
        if start.id == root.messageId {
            out.append(contentsOf: members.filter { !seen.contains($0.id) })
        }
        return out
    }

    /// The whole thread of `root` in tree order, the root first (`.tree` mode thread view).
    static func whole(_ rootMessage: Message, root: PartRef, in messages: [Message]) -> [Message] {
        order(from: rootMessage, root: root, members: members(of: root, in: messages))
    }

    /// The branch the thread view shows for `path` (the drilled messages below the root, outermost
    /// first): the last one and everything under it. nil when it is not a loaded member.
    static func branch(_ path: [PartRef], root: PartRef, in messages: [Message]) -> [Message]? {
        guard let last = path.last else { return nil }
        let ms = members(of: root, in: messages)
        guard let top = ms.first(where: { $0.id == last.messageId }) else { return nil }
        return order(from: top, root: root, members: ms)
    }

    /// Messages under each member and under the root that are not unsent or deleted (a branch's
    /// reply count; the root's entry is the thread's count).
    static func counts(of root: PartRef, in messages: [Message]) -> [ID: Int] {
        let ms = members(of: root, in: messages)
        let ids = Set(ms.map(\.id))
        let byID = Dictionary(ms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [ID: Int] = [:]
        for m in ms where m.retractedAt == nil && m.deletedAt == nil {
            // Every ancestor of a live member counts it once (a cycle stops at the first repeat).
            var seen: Set<ID> = [m.id]
            var p = parentID(m, root: root, members: ids)
            while seen.insert(p).inserted {
                out[p, default: 0] += 1
                guard p != root.messageId, let pm = byID[p] else { break }
                p = parentID(pm, root: root, members: ids)
            }
        }
        return out
    }

    /// The drill path from the root down to `ref` (outermost first, `ref` last), through the
    /// loaded parents; `[]` for the root itself. A parent that is not loaded ends the walk there.
    static func path(to ref: PartRef, root: PartRef, in messages: [Message]) -> [PartRef] {
        guard ref.messageId != root.messageId else { return [] }
        let ms = members(of: root, in: messages)
        let ids = Set(ms.map(\.id))
        let byID = Dictionary(ms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard let start = byID[ref.messageId] else { return [ref] }
        var chain: [PartRef] = [ref]
        var seen: Set<ID> = [ref.messageId]
        var p = parentID(start, root: root, members: ids)
        while p != root.messageId, seen.insert(p).inserted, let pm = byID[p] {
            chain.append(PartRef(messageId: pm.id, partIndex: 0))
            p = parentID(pm, root: root, members: ids)
        }
        return chain.reversed()
    }
}
