import AppKit
import SwiftUI

/// Owns the single shared-terminal size panel popover. Every entrypoint (tab
/// accessory, pane chip, context menu, palette, shortcut) presents through
/// here with an anchor in the tab strip, so the panel always hangs from the
/// terminal's tab.
@MainActor
final class TerminalSizePanelPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private(set) var surfaceID: UUID?
    /// The mouse-down that closed the panel, so the same click's mouse-up on
    /// the tab accessory does not reopen it.
    private var closingClick: (eventNumber: Int, surfaceID: UUID)?

    /// Whether the panel is open for `surfaceID`.
    func isShowing(surfaceID: UUID) -> Bool {
        popover?.isShown == true && self.surfaceID == surfaceID
    }

    /// Opens the panel below `anchor`, replacing any open panel.
    ///
    /// - Parameters:
    ///   - content: The panel view.
    ///   - surfaceID: The terminal the panel controls.
    ///   - anchor: The tab strip view to point at (accessory or tab item).
    ///   - rect: The rect in `anchor` to point at; its bounds when nil.
    func present<Content: View>(_ content: Content, surfaceID: UUID, anchor: NSView, rect: NSRect? = nil) {
        popover?.close()
        closingClick = nil
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = host
        popover.delegate = self
        self.popover = popover
        self.surfaceID = surfaceID
        // Below the tab, with the arrow pointing up at it.
        popover.show(relativeTo: rect ?? anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
    }

    /// Toggle semantics for the tab accessory: closes an open panel for this
    /// terminal, and ignores the click whose mouse-down just closed it.
    ///
    /// - Returns: `true` when the request was consumed as a close.
    func consumeToggleClose(surfaceID: UUID) -> Bool {
        if isShowing(surfaceID: surfaceID) {
            close()
            return true
        }
        guard let closingClick, closingClick.surfaceID == surfaceID,
              let event = NSApp.currentEvent, event.type == .leftMouseUp,
              event.eventNumber == closingClick.eventNumber else { return false }
        self.closingClick = nil
        return true
    }

    /// Closes the panel, or only when it controls `surfaceID` if given.
    func close(surfaceID: UUID? = nil) {
        guard surfaceID == nil || surfaceID == self.surfaceID else { return }
        popover?.close()
    }

    // MARK: NSPopoverDelegate

    func popoverWillClose(_ notification: Notification) {
        if let surfaceID, let event = NSApp.currentEvent, event.type == .leftMouseDown {
            closingClick = (event.eventNumber, surfaceID)
        } else {
            closingClick = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        popover = nil
        surfaceID = nil
    }
}
