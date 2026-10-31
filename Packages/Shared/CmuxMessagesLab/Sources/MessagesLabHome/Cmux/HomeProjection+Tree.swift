import CmuxHomeCore

/// Message links in a nested thread (host-hooks-b, `ThreadMode.tree`): a permalink
/// `<scheme>://conversation/<c>/message/<m>` (the docked Home's hand-off `#/conversation/<c>/message/<m>`)
/// opens the message's thread at its branch, any depth; the open branch is the selection a switch to
/// Channels hands over. Ids here are the owner's message ids; MessagesLab's are HomeStore keys
/// (`HomeMapping.id`). The tree itself is the daemon's (`reply_to` parents, HomeMapping+Tree.swift);
/// MessagesLab's ThreadTree walks those parents over the loaded window.
extension HomeProjection {
    /// Opens `message`: a thread reply opens its thread at its own branch (the owner's path from the
    /// root down to it, `conversation-link-resolve`), a root with replies opens its thread, any other
    /// message only shows the conversation. A message older than the loaded window loads older pages
    /// until it is in (one page per refresh, never a wait for a scroll); a later reveal, a thread action
    /// of the user, or a full history without it ends the request.
    func reveal(_ message: MessageID) {
        pendingReveal = message
        if placesOnOpen { revealedBeforePlacing = true }
        tree.target = nil
        tree.pages = 0
        let homeStore = self.homeStore, conversation = self.conversation
        // task-owner: one link resolve; ends with the owner's answer
        Task { [weak self] in
            let target = await homeStore.resolveLink(conversation, message: message)
            guard let self, self.pendingReveal == message else { return }
            self.tree.target = target
            self.revealIfLoaded()
        }
        revealIfLoaded()
    }

    func threadMovedByUser() { pendingReveal = nil }

    /// One older page toward the waiting permalink (its seq is below the window), or the end of the request.
    private func pageTowardReveal() {
        // The shown window (what revealIfLoaded reads), never the store's newer mirror; at most 50 pages.
        let oldest = shown.compactMap(\.seq).min()
        let below = tree.target?.seq.map { seq in oldest.map { seq < $0 } ?? true } ?? true
        guard hasOlder, below, tree.pages < 50 else {
            if !shown.isEmpty { pendingReveal = nil }  // the history holds no such message
            return
        }
        guard !tree.paging else { return }
        tree.paging = true
        tree.pages += 1
        let homeStore = self.homeStore, conversation = self.conversation
        // task-owner: one page read; the refresh it causes asks for the next one
        Task { [weak self] in
            await homeStore.loadOlder(conversation)
            // The refresh this page causes calls revealIfLoaded (the page is not in `shown` yet here).
            self?.tree.paging = false
        }
    }

    func revealIfLoaded() {
        guard let target = pendingReveal, let store = controller.store else { return }
        guard let item = shown.first(where: { $0.messageID == target }) else {
            pageTowardReveal()
            return
        }
        pendingReveal = nil
        let id = HomeMapping.id(item, aliases: aliases)
        let messages = store.state.conversation.messages
        guard let m = messages.first(where: { $0.id == id }) else { return }
        let ref = PartRef(messageId: id, partIndex: 0)
        let root = m.replyTo ?? ref
        guard m.replyTo != nil || messages.contains(where: { $0.replyTo?.messageId == id && $0.id != id }) else { return }
        // The owner's path when every message on it is loaded, else the loaded parents' walk.
        let owned = (tree.target?.path ?? []).compactMap { pid in shown.first { $0.messageID == pid }.map { HomeMapping.id($0, aliases: aliases) } }
        // A path the owner cut (`truncated`: it starts below the root) falls back to the loaded walk.
        let path = tree.target.map { owned.count == $0.path.count && owned.count > 1 && $0.path.first == $0.threadRoot } == true
            ? owned.map { PartRef(messageId: $0, partIndex: 0) } : [root] + ThreadTree.path(to: ref, root: root, in: messages)
        tree.target = nil
        controller.dispatch(.openThreadPath(path))
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
