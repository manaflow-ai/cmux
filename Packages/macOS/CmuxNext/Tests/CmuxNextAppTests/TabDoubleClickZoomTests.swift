import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextApp
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

typealias ZoomStripID = CmuxNextTabs.TabID

/// #25624, cmux classic's pane zoom: double-clicking a tab zooms its pane to fill the workspace
/// (Toggle Pane Zoom, Cmd-Shift-Return's action) and again restores the layout. The zoom indicator is
/// the pane's, at its top-right (PaneZoomIndicatorTests): a zoom never narrows the strip and no tab moves.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabDoubleClickZoomTests {
    final class StripHarness {
        let model: TabStripModel
        let strip: TabStripView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        private(set) var intents: [TabStripIntent] = []

        init(renames: Bool = false) {
            let tabs = (0..<3).map { TabItem(id: ZoomStripID("tab\($0)"), title: "A tab with a long enough title \($0)") }
            model = TabStripModel(tabs: tabs, selectedID: ZoomStripID("tab0"))
            strip = TabStripView(model: model)
            strip.dragsWindowFromEmptySpace = false
            strip.renamesOnDoubleClick = renames
            strip.frame = NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight)
            window.contentView = strip
            window.orderFrontRegardless()
            strip.layoutSubtreeIfNeeded()
            model.intentHandler = { [unowned self] intent in intents.append(intent) }
        }

        /// The left part of tab `id`'s title, in window coordinates (no close button there).
        func body(_ id: ZoomStripID) throws -> CGPoint {
            let cell = try #require(strip.cells[id])
            let point = CGPoint(x: cell.frame.minX + cell.frame.width * 0.3, y: cell.frame.midY)
            return strip.convert(strip.convert(point, from: strip.tabsClip), to: nil)
        }

        /// A press and release; `clickCount` 2 is the second click of a double-click.
        func click(_ point: CGPoint, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1) else { continue }
                window.sendEvent(event)
            }
        }

        func doubleClick(_ point: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
            click(point, modifiers: modifiers)
            click(point, clickCount: 2, modifiers: modifiers)
        }

        /// The pane zooms or restores: the App's `PaneController.apply` sets the model, the strip syncs.
        func setZoomed(_ zoomed: Bool) {
            model.zoomsSelected = zoomed
            strip.syncFromModel()
            strip.layoutSubtreeIfNeeded()
        }

        var zooms: [ZoomStripID] { intents.compactMap { if case .toggleZoom(let id) = $0 { id } else { nil } } }

        func tearDown() { window.closeAfterTest() }
    }

    // MARK: The double-click

    /// The first click selects the tab, the second asks once to zoom its pane; a second
    /// double-click asks again (the App's toggle restores the layout).
    @Test func doubleClickingATabTogglesItsPanesZoom() throws {
        let harness = StripHarness()
        defer { harness.tearDown() }
        let tab = ZoomStripID("tab1")
        harness.doubleClick(try harness.body(tab))
        #expect(harness.zooms == [tab], "\(harness.intents)")
        #expect(harness.intents.first == .select(tab), "the first click selects the tab")
        #expect(harness.strip.inlineRenameField == nil, "a pane's tab does not rename on double-click")
        harness.doubleClick(try harness.body(tab))
        #expect(harness.zooms == [tab, tab])
    }

    /// One click selects and never zooms.
    @Test func aSingleClickDoesNotZoom() throws {
        let harness = StripHarness()
        defer { harness.tearDown() }
        harness.click(try harness.body(ZoomStripID("tab2")))
        #expect(harness.zooms.isEmpty)
    }

    /// A Cmd or Shift double-click changes the selection only.
    @Test(arguments: [NSEvent.ModifierFlags.command, .shift])
    func aModifiedDoubleClickDoesNotZoom(_ modifiers: NSEvent.ModifierFlags) throws {
        let harness = StripHarness()
        defer { harness.tearDown() }
        harness.doubleClick(try harness.body(ZoomStripID("tab1")), modifiers: modifiers)
        #expect(harness.zooms.isEmpty)
    }

    /// The screen bar keeps renaming on double-click.
    @Test func theScreenBarStillRenames() throws {
        let harness = StripHarness(renames: true)
        defer {
            harness.strip.cancelInlineRename()
            harness.tearDown()
        }
        harness.doubleClick(try harness.body(ZoomStripID("tab1")))
        #expect(harness.zooms.isEmpty)
        #expect(harness.strip.inlineRenameField != nil)
    }

    /// The pane runs Toggle Pane Zoom on itself (not the tab: a window's own page is in no store).
    @Test func thePaneZoomsItselfThroughToggleSplitZoom() {
        let invocation = PaneController.zoomInvocation(pane: "pane:7")
        #expect(PaneToolbar.zoom == "toggleSplitZoom")
        #expect(invocation.target == ActionTargetRef(kind: .pane, id: "pane:7"))
        #expect(invocation.origin == .user)
    }

    // MARK: The zoomed state on the selected tab (the indicator is the pane's: PaneZoomIndicatorTests)

    /// VoiceOver: a zoomed pane's selected tab says so and offers Exit Zoom, which toggles the zoom.
    @Test func voiceOverReadsAndExitsTheZoom() throws {
        let harness = StripHarness()
        defer { harness.tearDown() }
        let tab = ZoomStripID("tab0")
        let element = try #require(harness.strip.cells[tab]?.accessibility)
        #expect(element.accessibilityCustomActions()?.contains { $0.name == Strings.exitZoom } != true)
        harness.setZoomed(true)
        #expect(element.accessibilityLabel()?.contains(Strings.axZoomed) == true)
        let action = try #require(element.accessibilityCustomActions()?.first { $0.name == Strings.exitZoom })
        _ = action.handler?()
        #expect(harness.zooms == [tab])
        harness.setZoomed(false)
        #expect(element.accessibilityLabel()?.contains(Strings.axZoomed) != true)
    }

    /// The strip itself never moves a tab for a zoom (the toolbar's width is checked below).
    @Test func aZoomMovesNoTab() {
        let harness = StripHarness()
        defer { harness.tearDown() }
        let frames = { harness.strip.cells.mapValues(\.frame) }
        let before = frames()
        harness.setZoomed(true)
        #expect(frames() == before)
        harness.setZoomed(false)
        #expect(frames() == before)
    }

    // MARK: The pane's toolbar

    final class Toolbar {
        let registry = ActionRegistry.standard()
        private(set) var zooms: [ActionInvocation] = []
        private(set) lazy var toolbar: PaneToolbar = {
            let registry = self.registry
            let toolbar = PaneToolbar(registry: { registry })
            // A pane's bar has room for its buttons: a zero-width bar hides every button that does not fit and
            // "…" offers it instead (#26132), which is not what these cases are about.
            toolbar.view.frame = NSRect(x: 0, y: 0, width: 240, height: TabStripView.preferredHeight)
            return toolbar
        }()

        init() {
            registry.bind("toggleSplitZoom", invoke: { [unowned self] in zooms.append($0) })
            registry.bind("splitRight", invoke: { _ in })
        }
    }

    /// A zoom shows the bar's one Exit Zoom button in its trailing slot (no pinned buttons appear), and the tab bar's
    /// right-click still offers Toggle Pane Zoom (its More, the pane's rows) now that the pane's "…" is gone.
    @Test func aZoomShowsOnlyExitZoom() throws {
        let harness = Toolbar()
        let toolbar = harness.toolbar
        toolbar.update(target: "tab0", kind: .terminal, paneKinds: [.terminal])
        #expect(toolbar.view.intrinsicContentSize.width == 0, "nothing pinned: the strip has the whole row")
        #expect(toolbar.view.reservedCount == 0)

        toolbar.update(target: "tab0", kind: .terminal, zoomed: true, paneKinds: [.terminal])
        #expect(toolbar.view.buttons.isEmpty, "the indicator is the pane's, not a toolbar button")
        #expect(!toolbar.view.zoomButton.isHidden)
        #expect(toolbar.view.intrinsicContentSize.width == PaneToolbarView.trailingGap + TitlebarBandButton.side)
        let more = try #require(harness.registry.makeTabStripMenu(target: ActionTargetRef(kind: .pane, id: "p")).items.last?.submenu)
        #expect(more.items.contains { ActionRegistry.menuRun(of: $0)?.id == "toggleSplitZoom" })
    }

    /// A chat selected in a zoomed pane keeps the same room: selecting it moves no tab.
    @Test func aZoomedPaneKeepsItsRoomWhicheverTabIsSelected() {
        let harness = Toolbar()
        let toolbar = harness.toolbar
        toolbar.update(target: "tab0", kind: .terminal, zoomed: true, paneKinds: [.terminal])
        let width = toolbar.view.intrinsicContentSize.width
        toolbar.update(target: "chat", kind: nil, zoomed: true, paneKinds: [.terminal])
        #expect(toolbar.view.items.isEmpty)
        #expect(toolbar.view.intrinsicContentSize.width == width, "the strip's width does not follow the selection")
    }

    /// A pinned zoom gives way to the bar's one Exit Zoom button while the pane is zoomed, so the pane shows one zoom
    /// mark, never two (1d6a69b797566d, user 2026-11-09); it comes back, unlit, once the zoom ends.
    @Test func aPinnedZoomGivesWayToExitZoomWhileZoomed() {
        let harness = Toolbar()
        let toolbar = harness.toolbar
        toolbar.update(target: "tab0", kind: .terminal, zoomed: true, pinned: ["splitRight", "toggleSplitZoom"])
        #expect(toolbar.view.items.map(\.id) == ["splitRight"])
        #expect(!toolbar.view.zoomButton.isHidden, "the one zoom mark")
        toolbar.update(target: "tab0", kind: .terminal, zoomed: false, pinned: ["splitRight", "toggleSplitZoom"])
        #expect(toolbar.view.items.map(\.id) == ["splitRight", "toggleSplitZoom"])
        #expect(toolbar.view.items.map(\.lit) == [false, false])
        #expect(toolbar.view.zoomButton.isHidden)
    }
}
