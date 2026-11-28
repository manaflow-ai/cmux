import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxVisibleRows
import CmuxVisibleRowsTesting
import QuartzCore
import Testing

/// The sidebar's Priority view under the visible-rows contract (`VisibleRowsContract`), at 100 and 10,000 chats.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct SidebarPriorityVisibleRowsTests {
    @Test func sidebarPriority() async throws {
        try await VisibleRowsContract.check(SidebarPriorityRows.self)
    }
}

/// The Priority view over `rows` idle chats in a 240 x 600 window, its rows laid out and drawn.
@MainActor final class SidebarPriorityRows: VisibleRowsFixture {
    static let name = "sidebar priority"
    let panel = SidebarPriorityPanelView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
    let window: NSWindow
    var entries: [SidebarPriorityEntry]
    var list: SidebarPriorityPanelView { panel }
    var clip: NSClipView { panel.clip }

    init(rows: Int) async throws {
        _ = NSApplication.shared
        entries = (0..<rows).map { SidebarPriorityEntry(id: "vr-\($0)", title: "chat \($0)", state: .idle) }
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 600), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        window.orderFrontRegardless()
        panel.show(SidebarPriorityPanel(entries: entries))
        drawFrame()
    }

    private func drawFrame() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    var viewportRows: Int { panel.rows.values.filter { clip.bounds.intersects($0.frame) }.count }

    /// A shown chat's title changes, as the App's next ranking delivers it.
    func changeOneItem() async throws {
        entries[2].title = "renamed"
        panel.show(SidebarPriorityPanel(entries: entries))
        drawFrame()
    }

    /// From the middle of the list (that move is not measured), one row down.
    func scrollOneRow() async throws -> Bool {
        let step = SidebarPriorityRowView.height(hasPreview: false)
        let maxY = max(0, panel.document.frame.height - clip.bounds.height)
        guard maxY > step else { return false }
        clip.scroll(to: NSPoint(x: 0, y: min(maxY / 2, 2_000)))
        drawFrame()
        _ = panel.listWork.take()
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + step))
        drawFrame()
        return true
    }

    /// One live-resize step of the sidebar: 8 pt narrower.
    func resizeOneStep() async throws -> Bool {
        window.setContentSize(NSSize(width: 232, height: 600))
        drawFrame()
        return true
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}
