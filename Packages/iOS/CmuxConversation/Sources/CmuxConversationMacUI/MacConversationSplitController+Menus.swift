#if os(macOS)
import AppKit
import CmuxConversationCore

extension MacConversationLab {
    /// File > New Message (⌘N) and the toolbar compose button open the
    /// window's draft conversation (`newMessage(prefill:)`). A host with its
    /// own New Message flow installs it here instead.
    @MainActor public static var composeHandler: (@MainActor (NSWindow?) -> Void)?
}

/// Messages' window-level menu commands: File, Edit > Search, View and
/// Conversation. Conversation actions go through the sidebar's
/// `perform(_:on:)`, the path its context menu and swipes take.
extension MacConversationSplitController: MacConversationCommandValidating, NSMenuItemValidation {
    private var selectedListState: (state: ConversationListState, isUnread: Bool)? {
        selected.flatMap { sidebar.entryState($0.id) }
    }

    private var contactCardParticipant: ConversationParticipant? {
        guard let store = selected?.store, let info = store.info, info.kind == .direct else { return nil }
        let others = info.participants.filter { $0.id != store.meID && !$0.isMe }
        return others.count == 1 ? others[0] : nil
    }

    func canPerform(_ action: Selector) -> Bool {
        switch action {
        case #selector(newMessage(_:)): return MacConversationLab.composeHandler != nil || entries.contains { $0.backend != nil }
        case #selector(openConversationInNewWindow(_:)): return selected?.canReopen == true
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)): return selected != nil && !sidebar.query.isEmpty
        case #selector(makeTextBigger(_:)): return MacConversationTextSize.canMakeBigger
        case #selector(makeTextSmaller(_:)): return MacConversationTextSize.canMakeSmaller
        case #selector(makeTextNormalSize(_:)): return !MacConversationTextSize.isNormal
        case #selector(showContactCard(_:)): return contactCardParticipant != nil
        case #selector(markConversationUnread(_:)), #selector(toggleConversationAlerts(_:)), #selector(deleteConversation(_:)):
            return selectedListState != nil
        case #selector(markAllConversationsRead(_:)):
            return entries.contains { sidebar.entryState($0.id)?.isUnread == true }
        default: return true
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return false }
        switch action {
        case #selector(markConversationUnread(_:)):
            menuItem.title = selectedListState?.isUnread == true ? MacListStrings.markRead : MacListStrings.markUnread
        case #selector(toggleConversationAlerts(_:)):
            menuItem.state = selectedListState?.state.muted == true ? .on : .off
        case #selector(filterUnread(_:)): menuItem.state = sidebar.filter == .unread ? .on : .off
        case #selector(filterDrafts(_:)): menuItem.state = sidebar.filter == .drafts ? .on : .off
        case #selector(filterSendLater(_:)): menuItem.state = sidebar.filter == .sendLater ? .on : .off
        default:
            if !responds(to: action) { return super.validateUserInterfaceItem(menuItem) }
        }
        return canPerform(action)
    }

    // MARK: File

    /// File > Open Conversation in New Window.
    @objc func openConversationInNewWindow(_ sender: Any?) {
        guard let entry = selected, MacConversationLab.openConversationWindow(entry, from: view.window) != nil else { return NSSound.beep() }
    }

    // MARK: Edit > Search

    /// Edit > Search > Find Next (⌘G): the next transcript match for the
    /// sidebar search, wrapping at the newest message.
    @objc func findNextMatch(_ sender: Any?) {
        guard let controller = selected?.controller, controller.findMatch(sidebar.query, forward: true) else { return NSSound.beep() }
    }

    /// Edit > Search > Find Previous (⇧⌘G).
    @objc func findPreviousMatch(_ sender: Any?) {
        guard let controller = selected?.controller, controller.findMatch(sidebar.query, forward: false) else { return NSSound.beep() }
    }

    // MARK: View

    /// View > Make Text Bigger (⌘+).
    @objc func makeTextBigger(_ sender: Any?) { MacConversationTextSize.makeBigger() }

    /// View > Make Text Normal Size (⌥⌘0).
    @objc func makeTextNormalSize(_ sender: Any?) { MacConversationTextSize.makeNormal() }

    /// View > Make Text Smaller (⌘-).
    @objc func makeTextSmaller(_ sender: Any?) { MacConversationTextSize.makeSmaller() }

    /// View > Filter By > Unread (⌃⌘U). Choosing the active filter again lists everything.
    @objc func filterUnread(_ sender: Any?) { toggleFilter(.unread) }

    /// View > Filter By > Drafts.
    @objc func filterDrafts(_ sender: Any?) { toggleFilter(.drafts) }

    /// View > Filter By > Send Later.
    @objc func filterSendLater(_ sender: Any?) { toggleFilter(.sendLater) }

    private func toggleFilter(_ filter: MacConversationListFilter) {
        if let item = splitViewItems.first, item.isCollapsed { item.animator().isCollapsed = false }
        sidebar.setFilter(sidebar.filter == filter ? .all : filter)
    }

    // MARK: Conversation

    /// Conversation > Show Contact Card (⌥⌘B): the other person's card, under the name.
    @objc func showContactCard(_ sender: Any?) {
        guard let participant = contactCardParticipant else { return NSSound.beep() }
        contactCard?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = MacMentionCardController(participant: participant)
        contactCard = popover
        let anchor = titleNameLabel
        if anchor.window?.isVisible == true {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }
    }

    /// Conversation > Mark as Unread / Mark as Read (⇧⌘U).
    @objc func markConversationUnread(_ sender: Any?) { performListAction(.toggleUnread) }

    /// Conversation > Mark All as Read (⌥⇧⌘U).
    @objc func markAllConversationsRead(_ sender: Any?) {
        for entry in entries where sidebar.entryState(entry.id)?.isUnread == true {
            sidebar.perform(.toggleUnread, on: entry)
        }
    }

    /// Conversation > Hide Alerts (⌥⌘M).
    @objc func toggleConversationAlerts(_ sender: Any?) { performListAction(.toggleAlerts) }

    /// Conversation > Delete Conversation… (asks first, as the context menu does).
    @objc func deleteConversation(_ sender: Any?) { performListAction(.delete) }

    private func performListAction(_ action: MacConversationListAction) {
        guard let entry = selected else { return NSSound.beep() }
        sidebar.perform(action, on: entry)
    }
}
#endif
