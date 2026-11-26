import AppKit

/// Deduplicates main-window title writes at the AppKit boundary.
///
/// Terminal-title rate limiting is owned upstream by
/// ``GhosttyTitleUpdateDispatcher`` and the TabManager/Dock panel coalescer.
/// This writer deliberately owns no pending state or timer; it only prevents
/// an unchanged title from becoming another Dock/Spaces mutation.
@MainActor
final class WindowTitleWriter {
    func apply(_ title: String, to window: NSWindow) {
        guard window.title != title else { return }
        window.title = title
    }
}
