import AppKit
@testable import CmuxNextDesign
import Testing

/// SwiftUI pages' more buttons (the bookmark manager's) are the app's one ``OverflowButton`` (⋮,
/// Leo 2026-10-20, #22972): their menu lists the page's rows in order and a chosen row runs once.
@MainActor @Suite(.serialized) struct OverflowMenuButtonTests {
    @Test func theMenuListsTheRowsAndRunsTheChosenOne() throws {
        _ = NSApplication.shared
        let target = OverflowMenuTarget()
        var ran: [String] = []
        target.items = [
            .action("Add Bookmark…") { ran.append("add") },
            .separator,
            .action("Export…") { ran.append("export") },
        ]
        let menu = target.menu(in: .app)
        #expect(menu.items.map(\.title) == ["Add Bookmark…", "", "Export…"])
        #expect(menu.items[1].isSeparatorItem)

        // A click on the themed row (as in ThemedMenuTests) runs it once the menu's tracking loop has ended.
        let row = try #require(menu.items[2].view as? ThemedMenuRowView, "the row is cmux-drawn")
        let point = NSPoint(x: 30, y: row.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            type == .leftMouseDown ? row.mouseDown(with: event) : row.mouseUp(with: event)
        }
        let deadline = Date(timeIntervalSinceNow: 0.5)
        while ran.isEmpty, Date() < deadline { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
        #expect(ran == ["export"])
    }

    @Test func theHitTargetIsTheSidebarControls() {
        #expect(OverflowMenuButton.side == Metrics.iconSize + Metrics.space2)
        #expect(OverflowMenuButton.side > OverflowButton.glyphSize)
    }
}
