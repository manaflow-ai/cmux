import AppKit

/// The All chats table. NSTableView handles a click on a plain view itself (it selects the row),
/// so a chat row only opened from VoiceOver. Its row views take their own mouse down, so one
/// click opens the chat like every sidebar item (the cloud tree rule).
final class SidebarChatsTable: NSTableView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is SidebarItemRowView { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}
