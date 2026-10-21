import CmuxHomeCore

/// Nested threads (MessagesLab `ThreadMode.tree`, host-hooks-b; the daemon's conversation-tree-v1):
/// HomeStore's `replyTo` is the message a thread reply answers, at any depth, and `threadRoot`
/// its top root. MessagesLab keeps `replyTo` = the root (`HomeMapping.replyTo`) and takes the
/// answered message as `Message.parent`. No rule is made here: the daemon owns the tree, this
/// only names the parent by its MessagesLab id.
extension HomeMapping {
    /// The owner message ids `roots(in:)` indexes: every thread root, and every parent a
    /// thread reply names (a parent is looked up the same way, by its owner id).
    static func indexed(_ items: [TranscriptItem]) -> Set<MessageID> {
        var wanted = Set(items.compactMap(\.threadRoot))
        for item in items where item.threadRoot != nil {
            if let p = item.replyTo?.message { wanted.insert(p) }
        }
        return wanted
    }

    /// A thread reply's parent as MessagesLab's `Message.parent`: the message it answers when that
    /// is not the root itself. nil for the root's own replies, a message that is no thread reply,
    /// and a parent that is not among the mapped items or is retracted (MessagesLab then hangs the
    /// reply under the root, ThreadTree.parentID).
    static func parent(_ item: TranscriptItem, roots: Roots) -> PartRef? {
        guard let root = item.threadRoot, root != item.messageID, let p = item.replyTo?.message, p != root, p != item.messageID,
              let r = roots(p) else { return nil }
        return PartRef(messageId: r.id, partIndex: 0)
    }
}
