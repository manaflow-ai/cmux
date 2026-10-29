import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextTabs
import Foundation
import Testing

typealias ZoomStripID = CmuxNextTabs.TabID

/// #25624, cmux classic's pane zoom: double-clicking a tab zooms its pane to fill the workspace
/// (Toggle Pane Zoom, Cmd-Shift-Return's action) and again restores the layout; while the pane is
/// zoomed its tab bar shows a lit zoom button, pinned or not, whose click restores the layout.
@MainActor @Suite(.serialized) struct TabDoubleClickZoomTests {
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

        var zooms: [ZoomStripID] { intents.compactMap { if case .toggleZoom(let id) = $0 { id } else { nil } } }

        func tearDown() { window.orderOut(nil) }
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

    // MARK: The indicator

    final class Toolbar {
        let registry = ActionRegistry.standard()
        private(set) var zooms: [ActionInvocation] = []
        private(set) lazy var toolbar = PaneToolbar(registry: { [registry] in registry }, newTabMenu: { nil })

        init() {
            registry.bind("toggleSplitZoom", invoke: { [unowned self] in zooms.append($0) })
            registry.bind("splitRight", invoke: { _ in })
        }
    }

    /// Unzoomed with nothing pinned: no buttons. Zoomed: a lit zoom button shows without hover, and
    /// "…"'s menu does not offer the zoom a second time.
    @Test func aZoomedPaneShowsALitZoomButton() throws {
        let harness = Toolbar()
        let toolbar = harness.toolbar
        toolbar.update(target: "tab0", kind: .terminal)
        #expect(toolbar.view.buttons.isEmpty)
        #expect(!toolbar.view.lit)

        toolbar.update(target: "tab0", kind: .terminal, zoomed: true)
        #expect(toolbar.view.items.map(\.id) == ["toggleSplitZoom"])
        #expect(toolbar.view.items.first?.lit == true)
        #expect(toolbar.view.items.first?.symbol == "arrow.down.right.and.arrow.up.left")
        #expect(toolbar.view.lit)
        #expect(!toolbar.view.reveal.isEnabled, "shown at rest, not only on hover")
        #expect(toolbar.view.reservedCount == 2, "room for the zoom button and \"…\"")
        let menu = try #require(toolbar.view.moreMenu?())
        #expect(!menu.items.contains { ActionRegistry.menuRun(of: $0)?.id == "toggleSplitZoom" })

        toolbar.update(target: "tab0", kind: .terminal)
        #expect(toolbar.view.buttons.isEmpty, "the indicator goes with the zoom")
    }

    /// The indicator's click runs Toggle Pane Zoom on the shown tab's pane: the layout comes back.
    @Test func clickingTheIndicatorRestoresTheLayout() throws {
        let harness = Toolbar()
        let toolbar = harness.toolbar
        toolbar.update(target: "tab0", kind: .terminal, zoomed: true)
        let button = try #require(toolbar.view.buttons.first)
        button.performClick(nil)
        #expect(harness.zooms.count == 1)
        #expect(harness.zooms.first?.target == ActionTargetRef(kind: .tab, id: "tab0"))
    }

    /// Pinned zoom keeps its one button, lit while zoomed.
    @Test func aPinnedZoomButtonIsNotDoubled() {
        let harness = Toolbar()
        let toolbar = harness.toolbar
        toolbar.update(target: "tab0", kind: .terminal, zoomed: true, pinned: ["splitRight", "toggleSplitZoom"])
        #expect(toolbar.view.items.map(\.id) == ["splitRight", "toggleSplitZoom"])
        #expect(toolbar.view.items.map(\.lit) == [false, true])
    }

    /// A chat selected in a zoomed pane shows no zoom button but keeps its room: selecting it moves no tab.
    @Test func aZoomedPaneKeepsTheIndicatorsRoomWhicheverTabIsSelected() {
        let harness = Toolbar()
        let toolbar = harness.toolbar
        toolbar.update(target: "tab0", kind: .terminal, zoomed: true, paneKinds: [.terminal])
        #expect(toolbar.view.reservedCount == 2)
        toolbar.update(target: "chat", kind: nil, zoomed: true, paneKinds: [.terminal])
        #expect(toolbar.view.items.isEmpty)
        #expect(toolbar.view.reservedCount == 2, "the strip's width does not follow the selection")
    }
}
