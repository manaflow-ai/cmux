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

/// Leo 2026-11-23, ask c-b5d3e0efb6: "the close cross was gone. why was it gone? no good fucking reason. so what, you cant
/// close a pinned tab? no good reason for these limitations." Pinning only moves an item to the top: a pinned row in
/// the sidebar (a Pinned block's workspace tile, a pinned workspace drawn as a list row) and a pinned tab in a pane's
/// tab strip keep the x an unpinned one shows on hover, the ⋮ keeps its regular place and opens the regular workspace
/// menu, Unpin sits where Pin sits, and nothing leads the row but its own icon. A pinned group header has no pin mark.
@MainActor @Suite(.serialized, .closesItsWindows) struct PinnedLikeRegularTests {
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

    static func workspace(of item: LayoutItem) -> CmuxNextSidebar.WorkspaceID {
        CmuxNextSidebar.WorkspaceID(item.ref.value.replacingOccurrences(of: "local:", with: ""))
    }

    /// A hovered pinned tile shows a workspace row's controls in a workspace row's slots: the x on the trailing column,
    /// the ⋮ one slot in, Unpin one more. The x closes the workspace, Unpin unpins it, and the ⋮ opens the workspace's
    /// own menu, not the item menu.
    @Test func aHoveredPinnedTileShowsTheRowsCloseMoreAndUnpin() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let pins = SidebarHoverPinTests.Pins(pinned: Set(SidebarHomePinnedDragHarness.pins.map(Self.workspace)))
        let harness = pins.harness
        defer { harness.close() }
        var closes: [[CmuxNextSidebar.WorkspaceID]] = []
        harness.list.model.onIntent = { if case let .close(ids) = $0 { closes.append(ids) } }
        for pin in SidebarHomePinnedDragHarness.pins {
            let workspace = Self.workspace(of: pin)
            let row = try harness.item(pin.id)
            Self.hover(row, in: harness)
            #expect(row.showsHoverActions, "\(row.titleText): no hover controls under the pointer")
            let close = try #require(row.hoverClose, "\(row.titleText): a pinned tile has no close x on hover")
            let more = try #require(row.hoverMore, "\(row.titleText): no more button on hover")
            #expect(Self.visibleCloses(in: row).count == 1, "\(row.titleText): a hovered pinned tile shows no close x")
            let column = SidebarStyle.trailingColumnCenterX(rowWidth: row.bounds.width - SidebarStyle.horizontalInset)
            let pitch = SidebarStyle.trailingSlotPitch
            #expect(abs(close.frame.midX - column) < 0.5, "\(row.titleText): the x left the column (\(close.frame.midX) vs \(column))")
            #expect(abs(more.frame.midX - (column - pitch)) < 0.5, "\(row.titleText): the more button is not one slot in from the x")
            let unpin = try #require(SidebarHoverPinTests.buttons(labelled: CmuxNextSidebar.Strings.unpinWorkspace, in: row).first,
                                     "\(row.titleText): no Unpin on hover")
            #expect(abs(unpin.frame.midX - (column - 2 * pitch)) < 0.5, "\(row.titleText): Unpin is not where a row's Pin is")
            #expect(row.moreMenuTarget(item: pin.id) == .workspaces([workspace]),
                    "\(row.titleText): the more button opens \(row.moreMenuTarget(item: pin.id)), not the workspace menu")
            _ = close.accessibilityPerformPress()
            #expect(closes.last == [workspace], "\(row.titleText): its x closed \(closes)")
            _ = unpin.accessibilityPerformPress()
            #expect(pins.toggled.last == workspace, "\(row.titleText): its Unpin ran \(pins.toggled)")
        }
        PointerHover.setDebugPointer(nil, in: harness.window)
    }

    /// A pinned tile leads as its list row does: no pin before its icon and title (Leo: "it puts a symbol at the left").
    @Test func aPinnedTileDrawsNoLeadingPin() throws {
        let harness = SidebarHomePinnedDragHarness()
        defer { harness.close() }
        for pin in SidebarHomePinnedDragHarness.pins {
            let row = try harness.item(pin.id)
            #expect(!row.info.leadingPin, "\(row.titleText): the pinned tile is configured with a leading pin")
            #expect(row.pinSquareFrame == nil, "\(row.titleText): the pinned tile draws a pin at its left")
        }
    }

    /// A pinned group's header draws no pin before its name, and its name starts where an unpinned group's does.
    @Test func aPinnedGroupHeaderLeadsAsAnUnpinnedOne() throws {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let pinnedID = GroupID("g-like-pinned"), plainID = GroupID("g-like-plain")
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
            .group(SidebarGroup(id: pinnedID, name: "Pinned group", color: .blue, isPinned: true,
                                workspaces: [SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("w-like-a"), title: "a")])),
            .group(SidebarGroup(id: plainID, name: "Plain group", color: .blue,
                                workspaces: [SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("w-like-b"), title: "b")])),
        ])])
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.rowViews.values.forEach { $0.needsLayout = true; $0.layoutSubtreeIfNeeded() }
        let pinned = try #require(list.rowViews[.group(pinnedID)] as? GroupHeaderRowView, "no pinned group header")
        let plain = try #require(list.rowViews[.group(plainID)] as? GroupHeaderRowView, "no unpinned group header")
        #expect(pinned.pinSquareFrame == nil, "the pinned group header draws a pin at its left")
        let pinnedName = list.convert(pinned.name.frame, from: pinned).minX, plainName = list.convert(plain.name.frame, from: plain).minX
        #expect(abs(pinnedName - plainName) <= 0.5, "the pinned group's name starts at \(pinnedName), an unpinned one's at \(plainName)")
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

    /// A pinned workspace drawn as a list row keeps its x on hover, and its ⋮ and Unpin sit where an unpinned row's ⋮
    /// and Pin do.
    @Test func aHoveredPinnedListRowKeepsItsCloseAndItsSlots() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let pinned = SidebarHomePinnedDragHarness.loose[1], unpinned = SidebarHomePinnedDragHarness.loose[2]
        let pins = SidebarHoverPinTests.Pins(pinned: [pinned])
        defer { pins.harness.close() }
        let plain = try pins.row(unpinned, hovered: true)
        let frames = (close: plain.closeButton.frame, more: plain.moreButton.frame, pin: plain.pinButton.frame)
        let row = try pins.row(pinned, hovered: true)
        #expect(!row.closeButton.isHidden && row.closeButton.alphaValue > 0, "a hovered pinned row shows no close x")
        #expect(SidebarHoverPinTests.shows(row.moreButton), "a hovered pinned row shows no more button")
        #expect(SidebarHoverPinTests.shows(row.pinButton), "a hovered pinned row shows no Unpin")
        #expect(row.closeButton.frame == frames.close, "the pinned row's x \(row.closeButton.frame) is not at \(frames.close)")
        #expect(row.moreButton.frame == frames.more, "the pinned row's more button \(row.moreButton.frame) moved from \(frames.more)")
        #expect(row.pinButton.frame == frames.pin, "the pinned row's Unpin \(row.pinButton.frame) is not where Pin is \(frames.pin)")
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

    /// A hovered pinned tab swaps its icon for the x, and a click on the x closes it.
    @Test func aHoveredPinnedTabShowsItsCloseAndTheCloseCloses() throws {
        let harness = StripHarness()
        defer { harness.window.closeAfterTest() }
        try harness.hover(StripHarness.pinned)
        let cell = try #require(harness.strip.cells[StripHarness.pinned])
        let rect = try #require(cell.closeButtonRect, "a hovered pinned tab shows no close x")
        let local = harness.strip.convert(CGPoint(x: cell.frame.minX + rect.midX, y: cell.frame.midY), from: harness.strip.tabsClip)
        harness.click(harness.strip.convert(local, to: nil))
        #expect(harness.closes == [StripHarness.pinned], "a click on the pinned tab's x closed \(harness.closes)")
    }

    @Test func aHoveredUnpinnedTabStillShowsItsClose() throws {
        let harness = StripHarness()
        defer { harness.window.closeAfterTest() }
        try harness.hover(StripHarness.loose)
        let cell = try #require(harness.strip.cells[StripHarness.loose])
        #expect(cell.closeButtonRect != nil, "a hovered unpinned tab lost its close x")
    }
}
