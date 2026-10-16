import CmuxHomeCore

/// Message links in a nested thread (host-hooks-b, `ThreadMode.tree`): a permalink
/// `<scheme>://conversation/<c>/message/<m>` (the docked Home's hand-off `#/conversation/<c>/message/<m>`)
/// opens the message's thread at its branch, any depth; the open branch is the selection a switch to
/// Channels hands over. Ids here are the owner's message ids; MessagesLab's are HomeStore keys
/// (`HomeMapping.id`). The tree itself is the daemon's (`reply_to` parents, HomeMapping+Tree.swift);
/// MessagesLab's ThreadTree walks those parents over the loaded window.
extension HomeProjection {
    /// Opens `message` once the shown window holds it: a thread reply opens its thread at its own
    /// branch (the path from the root down to it), a root with replies opens its thread, any other
    /// message only shows the conversation. It waits while the shown window does not hold it (the
    /// owner's first page, an older page the user scrolls to; no page is loaded for it); a later
    /// reveal, a thread action of the user, or a full history without it ends the wait.
    func reveal(_ message: MessageID) {
        pendingReveal = message
        revealIfLoaded()
    }

    func revealIfLoaded() {
        guard let target = pendingReveal, let store = controller.store else { return }
        guard let item = shown.first(where: { $0.messageID == target }) else {
            // The whole history is loaded and the message is not in it (deleted, another conversation): give up.
            if !shown.isEmpty, !hasOlder { pendingReveal = nil }
            return
        }
        pendingReveal = nil
        let id = HomeMapping.id(item, aliases: aliases)
        let messages = store.state.conversation.messages
        guard let m = messages.first(where: { $0.id == id }) else { return }
        let ref = PartRef(messageId: id, partIndex: 0)
        let root = m.replyTo ?? ref
        guard m.replyTo != nil || messages.contains(where: { $0.replyTo?.messageId == id && $0.id != id }) else { return }
        controller.dispatch(.openThreadPath([root] + ThreadTree.path(to: ref, root: root, in: messages)))
    }

    /// The owner's id of the message the open thread view shows: the drilled branch's message,
    /// else the root. nil with no thread open, or before the message has an owner id (my send).
    var openThreadMessage: MessageID? {
        guard let ui = controller.store?.state.ui, let open = ui.threadPath.last ?? ui.openThread else { return nil }
        return ownerID(open.messageId)
    }

    /// The open drill path, root first, as owner ids (nil: an entry with no owner id yet).
    var openThreadPath: [MessageID?] {
        guard let ui = controller.store?.state.ui, let root = ui.openThread else { return [] }
        return ([root] + ui.threadPath).map { ownerID($0.messageId) }
    }

    func ownerID(_ id: ID) -> MessageID? {
        (shown.first { HomeMapping.id($0, aliases: aliases) == id }
            ?? homeStore.transcript(for: conversation).first { HomeMapping.id($0, aliases: aliases) == id })?.messageID
    }
}
