import AppKit

/// The All chats header row (title, search, filter, grouping). While faded out
/// it takes no pointer clicks, so a hidden control is never pressed by accident;
/// it stays in the accessibility tree (VoiceOver users do not hover). Its
/// right-click menu is the section's (Hide Section).
final class SidebarChatsHeader: NSView {
    var onMenu: (() -> NSMenu?)?
    var isRevealed = false

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isRevealed ? super.hitTest(point) : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?() ?? super.menu(for: event)
    }
}
