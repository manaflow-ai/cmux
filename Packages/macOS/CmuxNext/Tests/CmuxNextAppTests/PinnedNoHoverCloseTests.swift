import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence msg 19392: "hover on pinned tab should not have close button, should only be able to close in right
/// click". A pinned row in the sidebar (a Pinned block's workspace, a band item such as "cmux Performance Lead", a
/// pinned workspace drawn as a list row) and a pinned tab in a pane's tab strip show no x on hover; the ⋮ stays, on
/// the trailing column the x took, and Close stays in the right-click menu. Unpinned rows and tabs keep their x.
@MainActor @Suite(.serialized, .closesItsWindows) struct PinnedNoHoverCloseTests {
    // MARK: Sidebar

    /// Every close x drawn in `view`'s subtree now: shown, not clear, labelled as the row close.
    static func visibleCloses(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ node: NSView, alpha: CGFloat) {
            let drawn = alpha * node.alphaValue
            guard !node.isHidden, drawn > 0.01 else { return }
            if node !== view, node.accessibilityLabel() == CmuxNextSidebar.Strings.closeButton { found.append(node) }
            node.subviews.forEach { walk($0, alpha: drawn) }
        }
        walk(view, alpha: 1)
        return found
    }

    /// Puts the synthesized pointer on `view`'s middle and lays the row out again.
    static func hover(_ view: NSView, in harness: SidebarHomePinnedDragHarness) {
        let middle = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        PointerHover.setDebugPointer(middle, in: harness.window)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    @Test func aHoveredPinnedRowShowsItsMoreButtonOnTheColumnAndNoClose() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let harness = SidebarHomePinnedDragHarness()
        defer { harness.close() }
        // "cmux Performance Lead" first: the row Lawrence hovered.
        for pin in SidebarHomePinnedDragHarness.pins {
            let row = try harness.item(pin.id)
            Self.hover(row, in: harness)
            #expect(row.showsHoverActions, "\(row.titleText): no hover controls under the pointer")
            let more = try #require(row.hoverMore, "\(row.titleText): no more button on hover")
            #expect(!more.isHiddenOrHasHiddenAncestor, "\(row.titleText): the more button hid on hover")
            #expect(Self.visibleCloses(in: row).isEmpty, "\(row.titleText): a pinned row showed a close x on hover")
            // The ⋮ takes the x's place, the end-most control on the trailing column: nothing else moves.
            let column = SidebarStyle.trailingColumnCenterX(rowWidth: row.bounds.width - SidebarStyle.horizontalInset)
            #expect(abs(more.frame.midX - column) < 0.5, "\(row.titleText): the more button left the column (\(more.frame.midX) vs \(column))")
        }
        PointerHover.setDebugPointer(nil, in: harness.window)
    }

    @Test func aHoveredUnpinnedRowStillShowsItsClose() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let harness = SidebarHomePinnedDragHarness()
        defer { harness.close() }
        let id = SidebarHomePinnedDragHarness.loose[0]
        harness.list.setHovered(.workspace(id))
        let row = try #require(harness.list.rowViews[.workspace(id)] as? WorkspaceRowView)
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        #expect(!row.closeButton.isHidden && row.closeButton.alphaValue > 0, "an unpinned row lost its hover close")
    }

    /// A pinned workspace drawn as a list row (an expanded row's Unpin, `SidebarModel.workspacePin`): no x on hover,
    /// its ⋮ in the x's place. An unpinned row beside it keeps its x.
    @Test func aHoveredPinnedListRowShowsNoClose() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let harness = SidebarHomePinnedDragHarness()
        defer { harness.close() }
        let pinned = SidebarHomePinnedDragHarness.loose[1], unpinned = SidebarHomePinnedDragHarness.loose[2]
        harness.list.model.workspacePin = (isPinned: { $0 == pinned }, toggle: { _ in })
        harness.list.contextMenuProvider = { _ in NSMenu() }
        harness.settle()
        // The x's place: where the unpinned row draws its hover close (the trailing column, #30232).
        var xPlace: CGRect?
        for (id, isPinned) in [(unpinned, false), (pinned, true)] {
            harness.list.setHovered(.workspace(id))
            let row = try #require(harness.list.rowViews[.workspace(id)] as? WorkspaceRowView)
            row.wire(id, in: harness.list) // the menu provider came after the row's first wiring
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            let closeShown = !row.closeButton.isHidden && row.closeButton.alphaValue > 0
            #expect(closeShown != isPinned, "\(id.rawValue) pinned \(isPinned): close shown \(closeShown)")
            #expect(!row.moreButton.isHidden && row.moreButton.alphaValue > 0, "\(id.rawValue): no more button on hover")
            if isPinned {
                let place = try #require(xPlace)
                #expect(row.moreButton.frame == place, "the more button \(row.moreButton.frame) did not take the x's place \(place)")
            } else {
                xPlace = row.closeButton.frame
            }
        }
    }

    /// Middle-click is left as it was: on a pinned band row it closes nothing (the list's middle click acts only on
    /// a workspace list row), on an unpinned list row it closes that workspace.
    @Test func middleClickKeepsWhatItDid() throws {
        let harness = SidebarHomePinnedDragHarness()
        defer { harness.close() }
        var closes: [[CmuxNextSidebar.WorkspaceID]] = []
        harness.list.model.onIntent = { if case let .close(ids) = $0 { closes.append(ids) } }
        let row = try harness.item(SidebarHomePinnedDragHarness.pins[0].id)
        let pinPoint = harness.list.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), from: row)
        harness.list.middleClick.pressDown(at: pinPoint, in: harness.list)
        harness.list.middleClick.pressUp(at: pinPoint, in: harness.list)
        #expect(closes.isEmpty, "a middle click on a pinned row closed \(closes)")
        let loose = SidebarHomePinnedDragHarness.loose[0]
        let listed = try #require(harness.list.displayed.row(for: .workspace(loose)))
        let point = NSPoint(x: harness.list.bounds.midX, y: (listed.y + listed.maxY) / 2)
        harness.list.middleClick.pressDown(at: point, in: harness.list)
        harness.list.middleClick.pressUp(at: point, in: harness.list)
        #expect(closes == [[loose]], "a middle click on an unpinned row did not close it: \(closes)")
    }

    /// The pinned row's right-click menu (the workspace menu `SidebarBridge.contextMenu` gives a pinned tile) still
    /// has Close Workspace.
    @Test func aPinnedRowsRightClickMenuStillCloses() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_pinned", title: "shell")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "pinned"), name: "pinned",
                                                                        screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        AppActions.bind(services)
        let menu = try #require(SidebarContextMenus.menu(for: .workspaces([CmuxNextSidebar.WorkspaceID(workspace.id)]),
                                                       model: SidebarModel(), services: services, scope: ThemeScope(level: .room),
                                                       workspaceMachineID: services.daemon.machineID))
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.compactMap(\.submenu).flatMap(items) }
        #expect(items(menu).contains { ActionRegistry.menuRun(of: $0)?.id == "closeWorkspace" },
                "the pinned row's right-click menu has no Close Workspace")
    }

    // MARK: Tab strip

    final class StripHarness {
        let model: TabStripModel
        let strip: TabStripView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        private(set) var closes: [CmuxNextTabs.TabID] = []
        static let pinned = CmuxNextTabs.TabID("pinned"), loose = CmuxNextTabs.TabID("loose"), selected = CmuxNextTabs.TabID("selected")

        init() {
            model = TabStripModel(tabs: [
                TabItem(id: Self.pinned, title: "Pinned", isPinned: true),
                TabItem(id: Self.loose, title: "Loose"),
                TabItem(id: Self.selected, title: "Selected"),
            ], selectedID: Self.selected)
            strip = TabStripView(model: model)
            strip.dragsWindowFromEmptySpace = false
            strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
            window.contentView = strip
            window.orderFrontRegardless()
            strip.layoutSubtreeIfNeeded()
            model.intentHandler = { [unowned self] intent in
                if case .close(let id, _) = intent { closes.append(id) }
            }
        }

        /// Moves the pointer onto tab `id`'s middle; returns that point in window coordinates.
        @discardableResult
        func hover(_ id: CmuxNextTabs.TabID) throws -> CGPoint {
            let cell = try #require(strip.cells[id])
            let middle = strip.convert(CGPoint(x: cell.frame.midX, y: cell.frame.midY), from: strip.tabsClip)
            TabStripDebug.pointerMoved(in: strip, to: middle)
            strip.layoutSubtreeIfNeeded()
            return strip.convert(middle, to: nil)
        }

        func click(_ point: CGPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                     pressure: type == .leftMouseUp ? 0 : 1) else { continue }
                window.sendEvent(event)
            }
        }
    }

    @Test func aHoveredPinnedTabShowsItsIconAndNoClose() throws {
        let harness = StripHarness()
        defer { harness.window.closeAfterTest() }
        let point = try harness.hover(StripHarness.pinned)
        let cell = try #require(harness.strip.cells[StripHarness.pinned])
        #expect(cell.closeButtonRect == nil, "a hovered pinned tab shows a close x")
        // A click where the x used to swap in selects the tab; it never closes it.
        harness.click(point)
        #expect(harness.closes.isEmpty, "a click on a hovered pinned tab closed it")
    }

    @Test func aHoveredUnpinnedTabStillShowsItsClose() throws {
        let harness = StripHarness()
        defer { harness.window.closeAfterTest() }
        try harness.hover(StripHarness.loose)
        let cell = try #require(harness.strip.cells[StripHarness.loose])
        #expect(cell.closeButtonRect != nil, "a hovered unpinned tab lost its close x")
    }
}
