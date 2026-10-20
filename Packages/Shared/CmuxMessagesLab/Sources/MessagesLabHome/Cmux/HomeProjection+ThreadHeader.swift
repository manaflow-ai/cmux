import AppKit
import CmuxHomeCore

/// The tree thread view's header (host-hooks-b ask 6) over the daemon's thread object
/// (conversation-thread-objects-v1, HomeStore `TranscriptItem.thread`): the title (the root's first
/// line when unset), the status chip (resolve / reopen) and the owner (assign). Every change goes to
/// the owner as `thread.update` (HomeOp.updateThread), the op the Channels page sends; the header
/// follows the owner's answer. Also each message's link ("Copy Link", the daemon's permalink form).
final class HomeTreeState {
    /// The owner's answer for the permalink waiting in `pendingReveal` (nil: none yet or no resolver).
    var target: HomeLinkTarget?
    /// An older page asked for a permalink is in flight; pages asked so far (a bound without a resolver).
    var paging = false
    var pages = 0
    /// The header the open thread view shows (a change re-asks MessagesLab).
    var header: ThreadHeaderContent?
    var popover: NSPopover?
    var commit: FieldCommit?
    var field: NSTextField?
    /// The build's link scheme (`cmux`, `cmux-dev`, `cmux-dev-<tag>`); nil: no Copy Link.
    var linkScheme: String?
}

/// Return in the rename field.
final class FieldCommit: NSObject {
    let run: (String) -> Void
    init(_ run: @escaping (String) -> Void) { self.run = run }
    @objc func fire(_ sender: NSTextField) { run(sender.stringValue) }
}

extension HomeProjection {
    /// Sets the header hooks on a newly made window view.
    func installThreadHeader() {
        guard let demo = controller.demo else { return }
        demo.hostHooks.threadHeader = { [weak self] root, _ in self?.threadHeader(root) }
        demo.hostHooks.threadHeaderAction = { [weak self] action, root, anchor in self?.threadHeaderAction(action, root: root, anchor: anchor) }
    }

    /// After each refresh: a changed header (the owner's thread object, a new reply, a name) is drawn again.
    func refreshThreadHeader() {
        guard let demo = controller.demo, let root = controller.store?.state.ui.openThread else { tree.header = nil; return }
        let now = threadHeader(root)
        guard now != tree.header else { return }
        tree.header = now
        demo.threadHeaderDidChange()
    }

    func threadHeader(_ root: PartRef) -> ThreadHeaderContent? {
        guard let item = shownItem(root.messageId), let mid = item.messageID else { return nil }
        let newest = shown.filter { $0.threadRoot == mid && $0.messageID != mid && !$0.isRetracted }.compactMap(\.seq).max()
        let firstLine = item.parts.map(\.plainText).joined(separator: " ").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let thread = item.thread
        let owner = thread?.owner.map { id in shownSummary?.participants.first { $0.id == id }?.displayName ?? id.rawValue }
        return ThreadHeaderContent(title: thread?.title ?? firstLine,
                                   status: thread?.status(newestReplySeq: newest) == .resolved ? .resolved : .open, owner: owner)
    }

    func threadHeaderAction(_ action: ThreadHeaderAction, root: PartRef, anchor: CGRect) {
        guard let mid = shownItem(root.messageId)?.messageID else { return }
        switch action {
        case .resolve: updateThread(mid, status: .resolved)
        case .reopen: updateThread(mid, status: .open)
        case .rename: presentRename(mid, anchor: anchor)
        case .assign: presentAssign(mid, anchor: anchor)
        }
    }

    /// `thread.update` through HomeStore (its queue, retry and the owner's answer).
    func updateThread(_ root: MessageID, title: String? = nil, status: ThreadInfo.Status? = nil, owner: String? = nil) {
        let homeStore = self.homeStore, conversation = self.conversation
        // task-owner: one op; ends with the owner's answer
        Task { _ = try? await homeStore.perform(.updateThread(conversation: conversation, root: root, title: title, status: status, owner: owner)) }
    }

    /// The header's title as an editable field in a popover; Return renames (empty: the root's first line again).
    func presentRename(_ root: MessageID, anchor: CGRect) {
        let host = controller.host
        tree.popover?.close()
        let current = shownItem(root)?.thread?.title ?? ""
        let field = NSTextField(string: current)
        field.cell?.sendsActionOnEndEditing = false  // a click outside only closes the popover
        field.placeholderString = CmuxStrings.threadTitlePlaceholder
        field.frame = CGRect(x: 12, y: 12, width: 260, height: 24)
        let commit = FieldCommit { [weak self] text in
            // The owner takes at most 200 characters; an unchanged title sends nothing (as Channels).
            let title = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            if title != current { self?.updateThread(root, title: title) }
            self?.tree.popover?.close()
        }
        field.target = commit
        field.action = #selector(FieldCommit.fire(_:))
        let content = NSViewController()
        content.view = NSView(frame: CGRect(x: 0, y: 0, width: 284, height: 48))
        content.view.addSubview(field)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        tree.popover = popover
        tree.commit = commit
        tree.field = field
        popover.show(relativeTo: hostRect(anchor), of: host, preferredEdge: .maxY)
        field.window?.makeFirstResponder(field)
    }

    /// The conversation's participants and "Unassigned" at the owner item.
    func presentAssign(_ root: MessageID, anchor: CGRect) {
        let current = shownItem(root)?.thread?.owner
        let menu = NSMenu()
        for p in shownSummary?.participants ?? [] {
            let item = MenuAction(title: p.displayName) { [weak self] in self?.updateThread(root, owner: p.id.rawValue) }
            item.state = p.id == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction(title: Strings.threadUnassigned) { [weak self] in self?.updateThread(root, owner: "") })
        let r = hostRect(anchor)
        menu.popUp(positioning: nil, at: CGPoint(x: r.minX, y: controller.host.isFlipped ? r.maxY : r.minY), in: controller.host)
    }

    /// A rect of the window view (top-left origin) in the host view.
    func hostRect(_ r: CGRect) -> CGRect {
        let host = controller.host
        return host.isFlipped ? r : CGRect(x: r.minX, y: host.bounds.height - r.maxY, width: r.width, height: r.height)
    }

    /// The message's permalink in the build's scheme (the daemon's form, conversation-link-resolve).
    func messageLink(_ id: ID) -> String? {
        guard let scheme = tree.linkScheme, let owner = ownerID(id) else { return nil }
        return "\(scheme)://conversation/\(conversation.rawValue)/message/\(owner.rawValue)"
    }

    func shownItem(_ id: ID) -> TranscriptItem? { shown.first { HomeMapping.id($0, aliases: aliases) == id } }
    func shownItem(_ id: MessageID) -> TranscriptItem? { shown.first { $0.messageID == id } }
}
