import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import Foundation
import Testing

/// Lawrence 2026-10-27: "too many buttons here" (the pane's top bar showed a terminal, a browser and
/// "⋮") and "i dont like dropdown design here" (the strip's "+" carried a chevron that opened the type
/// menu on press). The top bar keeps only "⋮", whose menu holds the same creation rows, and the strip's
/// "+" is a plain button: a press opens the default tab, a hold or a right-click opens the type menu.
/// Leo's "+ (v)" adds a separate pane-type chooser without changing that plain-plus action.
@MainActor @Suite(.serialized) struct PaneTabBarControlsTests {
    private static func tree(_ surfaces: [UInt64]) -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: surfaces.map { TabSnapshot(surface: SurfaceID(rawValue: $0), title: "~") })
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"tab-bar-controls-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    @Test func theTopBarOffersNoCreationButtonsOnlyItsMoreMenu() {
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil }, paneTarget: ActionTargetRef(kind: .pane, id: "sample-pane"))
        toolbar.update(target: "sample-terminal", kind: .terminal)
        #expect(toolbar.view.items.isEmpty, "the terminal and browser buttons repeat the + menu, which the ⋮ menu holds")
        #expect(toolbar.view.buttons.isEmpty)
        #expect(toolbar.view.hasMore, "the ⋮ stays for the pane's actions")
    }

    @Test func thePaneStripPlusIsAPlainButtonWithoutATypeMenuOnPress() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree([1]))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: WindowState(record: record))
        defer { pane.teardown() }
        let plus = pane.view.stripView.newTabButton
        #expect(!pane.view.stripView.opensNewTabMenuOnPress, "a press opens the default tab, not the type menu")
        #expect(!plus.showsChevron, "no caret on the pane's +")
        #expect(plus.accessibilityRole() == .button)

        let strip = pane.view.stripView
        let chooser = try #require(strip.accessibilityChildren()?.compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "cmux.tabs.newTabMenu" }, "pane types have their own visible chevron")
        #expect(!chooser.isHidden)
        #expect(chooser.accessibilityRole() == .popUpButton)
        strip.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
        strip.layoutSubtreeIfNeeded()
        #expect(chooser.frame.minX >= plus.frame.maxX)
        #expect(chooser.frame.maxX <= strip.bounds.width)
        let chooserPoint = chooser.convert(NSPoint(x: chooser.bounds.midX, y: chooser.bounds.midY), to: strip)
        #expect(strip.titlebarHit(at: chooserPoint) == .strip, "the chooser never drags the window")

        var intents: [TabStripIntent] = []
        strip.model.intentHandler = { intents.append($0) }
        var presentations = 0
        strip.presentNewTabMenu = { menu, _, _ in
            presentations += 1
            let actions = menu.items.compactMap { ActionRegistry.menuRun(of: $0) }
            #expect(Array(actions.prefix(3).map(\.id.rawValue)) == ["newSurface", "openBrowser.chromium", "palette.newAgentChat"])
            #expect(actions.prefix(3).allSatisfy { $0.target == ActionTargetRef(kind: .pane, id: pane.paneKey) })
            if presentations <= 2 { #expect(chooser.isHighlighted, "the chooser stays lit while its menu tracks") }
        }
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                                                  location: strip.convert(chooserPoint, to: nil), modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        strip.mouseDown(with: event)
        #expect(presentations == 1, "mouse-down opens the menu immediately")
        #expect(intents.isEmpty)
        #expect(!strip.pressedNewTab)
        #expect(!chooser.isHighlighted)
        #expect(chooser.accessibilityPerformPress())
        #expect(presentations == 2, "VoiceOver opens the same pane-target menu")

        #expect(plus.accessibilityPerformPress())
        #expect(intents == [.newTab(after: nil, sameKind: false)], "the plain + still creates the default tab")
        strip.showNewTabMenu()
        #expect(presentations == 3, "the existing hold/right-click entry point keeps the same menu")
    }

    @Test func theScreenBarKeepsItsOwnScreenMenuControl() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree([1]))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: WindowState(record: record))
        defer { withExtendedLifetime(services) { content.teardown() } }
        let bar = content.screenBar.view
        #expect(bar.opensNewTabMenuOnPress, "the screen bar's + opens its menu on press")
        #expect(bar.newTabButton.showsChevron, "the screen control retains its existing screen-menu caret")
        #expect(bar.accessibilityChildren()?.compactMap { $0 as? NSButton }
            .contains { $0.accessibilityIdentifier() == "cmux.tabs.newTabMenu" } != true,
            "a screen bar does not gain the pane-type chooser")
        #expect(bar.newTabToolTip == nil, "the + makes a screen, not a tab: no tab tooltip")
    }
}
