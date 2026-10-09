import AppKit
import Testing
@testable import MessagesLabSidebar

/// Messages shows no hover highlight on a conversation row or a pinned tile:
/// the pointer resting on one changes nothing that is drawn. These tests look
/// at the list document's own layers (where a hover fill would go) before and
/// after the pointer moves over a row and over a tile.
@MainActor @Suite(.serialized) struct SidebarNoHoverTests {
    /// The document's visible filled layers: frame and fill of each.
    private func fills(_ sidebar: SidebarController) -> [String] {
        (sidebar.document.layer?.sublayers ?? []).compactMap { l in
            guard !l.isHidden, l.opacity > 0, let fill = l.backgroundColor, fill.alpha > 0 else { return nil }
            return "\(l.frame) \(fill)"
        }
    }

    private func makeSidebar(pin: [ConversationID]) -> (SidebarController, PinningHost) {
        let host = PinningHost(count: 6)
        let sidebar = SidebarController()
        sidebar.dataSource = host
        sidebar.delegate = host
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
        sidebar.reloadData()
        for id in pin { sidebar.setPinned(true, id) }
        return (sidebar, host)
    }

    @Test func hoveringARowDrawsNoHighlight() {
        let (sidebar, host) = makeSidebar(pin: [])
        _ = host
        sidebar.select("c0", notify: false, reveal: false)
        let before = fills(sidebar)
        // Row 3: not selected, not the unread one.
        let r = sidebar.rowRect(3)
        sidebar.mouseMoved(CGPoint(x: r.midX, y: r.midY))
        #expect(fills(sidebar) == before)
        sidebar.mouseMoved(nil)
    }

    @Test func hoveringAPinnedTileDrawsNoHighlight() {
        let (sidebar, host) = makeSidebar(pin: ["c1", "c2"])
        _ = host
        #expect(sidebar.pinnedItems.count == 2)
        let before = fills(sidebar)
        let t = sidebar.tileRect(0)
        sidebar.mouseMoved(CGPoint(x: t.midX, y: t.midY))
        #expect(fills(sidebar) == before)
        sidebar.mouseMoved(nil)
    }
}
