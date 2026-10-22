import AppKit
@testable import CmuxNextTabs
import Testing

/// The vertical tab list sends the strip's intents (Leo 2026-10-20): a click selects, Cmd-click adds
/// to the selection, the speaker mutes, a header collapses its group, New Tab opens one, a right-click
/// asks for the strip's menus, and collapsing it reserves the narrow width.
@MainActor @Suite(.serialized) struct VerticalTabListViewTests {
    @MainActor final class Harness {
        let model: TabStripModel
        let list: VerticalTabListView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        private(set) var intents: [TabStripIntent] = []
        private(set) var menuTargets: [TabContextTarget] = []

        init() {
            var playing = TabItem(id: TabID("t2"), title: "Music")
            playing.audio = .playing
            model = TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "One"), TabItem(id: TabID("t1"), title: "Two"), playing,
                                         TabItem(id: TabID("g0"), title: "Grouped", groupID: TabGroupID("g"))],
                                  groups: [TabGroupItem(id: TabGroupID("g"), name: "Group", colorToken: .green)],
                                  selectedID: TabID("t0"))
            list = VerticalTabListView(model: model)
            list.frame = NSRect(x: 0, y: 0, width: VerticalTabListView.expandedWidth, height: 500)
            window.contentView = list
            window.orderFrontRegardless()
            list.layoutSubtreeIfNeeded()
            list.relayout()
            model.intentHandler = { [unowned self] intent in
                self.intents.append(intent)
                if case .select(let id) = intent { self.model.selectedID = id }
            }
            list.contextMenuProvider = { [unowned self] target in
                self.menuTargets.append(target)
                return NSMenu()
            }
        }

        /// A point in window coordinates inside the row of `kind`; `dx` from its leading edge, or its
        /// trailing edge when negative.
        func point(_ kind: VerticalTabListLayout.RowKind, dx: CGFloat = 12) throws -> CGPoint {
            let row = try #require(list.listLayout.rows.first { $0.kind == kind }, "no row \(kind)")
            let frame = list.viewRect(row.frame)
            return list.convert(CGPoint(x: dx >= 0 ? frame.minX + dx : frame.maxX + dx, y: frame.midY), to: nil)
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        func click(at point: CGPoint, _ modifiers: NSEvent.ModifierFlags = []) throws {
            list.mouseDown(with: try event(.leftMouseDown, at: point, modifiers))
            list.mouseUp(with: try event(.leftMouseUp, at: point, modifiers))
            list.relayout()
        }
    }

    @Test func clickingARowSelectsItAndCmdClickAddsIt() throws {
        let harness = Harness()
        defer { harness.window.orderOut(nil) }
        try harness.click(at: try harness.point(.tab(TabID("t1"))))
        #expect(harness.intents == [.select(TabID("t1"))])
        try harness.click(at: try harness.point(.tab(TabID("t2"))), .command)
        #expect(harness.model.selectedTabIDs == [TabID("t1"), TabID("t2")], "Cmd-click joins the strip's selection")
    }

    @Test func theSpeakerMutesWithoutSelecting() throws {
        let harness = Harness()
        defer { harness.window.orderOut(nil) }
        // Hover the row first: the speaker's place follows the close button's.
        let row = try harness.point(.tab(TabID("t2")))
        harness.list.updateHover(at: harness.list.convert(row, from: nil))
        let audioRow = try #require(harness.list.listLayout.rows.first { $0.kind == .tab(TabID("t2")) })
        let speaker = try #require(harness.list.audioFrame(audioRow))
        let at = harness.list.convert(CGPoint(x: speaker.midX, y: harness.list.viewRect(speaker).midY), to: nil)
        try harness.click(at: at)
        #expect(harness.intents == [.toggleAudioMute(TabID("t2"))])
    }

    @Test func theHeaderCollapsesItsGroupAndNewTabOpensOne() throws {
        let harness = Harness()
        defer { harness.window.orderOut(nil) }
        try harness.click(at: try harness.point(.groupHeader(TabGroupID("g"))))
        try harness.click(at: try harness.point(.newTab))
        #expect(harness.intents == [.toggleGroupCollapsed(TabGroupID("g")), .newTab(after: nil)])
    }

    @Test func rightClicksAskForTheStripsMenus() throws {
        let harness = Harness()
        defer { harness.window.orderOut(nil) }
        _ = harness.list.menu(for: try harness.event(.rightMouseDown, at: try harness.point(.tab(TabID("t1")))))
        _ = harness.list.menu(for: try harness.event(.rightMouseDown, at: try harness.point(.groupHeader(TabGroupID("g")))))
        _ = harness.list.menu(for: try harness.event(.rightMouseDown, at: try harness.point(.newTab)))
        _ = harness.list.menu(for: try harness.event(.rightMouseDown, at: harness.list.convert(CGPoint(x: 20, y: 480), to: nil)))
        #expect(harness.menuTargets == [.tab(TabID("t1"), selection: [TabID("t1")]), .group(TabGroupID("g")), .newTabButton, .emptyStrip])
    }

    @Test func collapsingReservesTheNarrowWidthAndHidesTitles() {
        let harness = Harness()
        defer { harness.window.orderOut(nil) }
        #expect(harness.list.reservedWidth == VerticalTabListView.expandedWidth)
        harness.list.isCollapsed = true
        #expect(harness.list.reservedWidth == VerticalTabListView.collapsedWidth)
        #expect(harness.list.listLayout.iconsOnly)
        var changes: [Bool] = []
        harness.list.onHoverExpansionChange = { changes.append($0) }
        harness.list.beginHoverExpansion()
        #expect(harness.list.isHoverExpanded && !harness.list.listLayout.iconsOnly, "hovered, it shows titles")
        #expect(harness.list.reservedWidth == VerticalTabListView.collapsedWidth, "hover never changes the reserved width")
        harness.list.endHoverExpansion()
        #expect(changes == [true, false])
    }
}
