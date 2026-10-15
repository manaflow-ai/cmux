import AppKit
import Foundation
import Testing
@testable import CmuxBrowser

/// Records requests and plays the engine's side of DevTools when asked.
@MainActor
private final class FakeDevToolsEngine: BrowserDevToolsEngineDriving {
    var supportsEmbeddedDevTools = true
    private(set) var requests: [BrowserDevToolsEngineRequest] = []
    private(set) var placements: [BrowserDevToolsPlacement] = []
    private(set) var focus: [Bool] = []

    func runDevToolsRequest(_ request: BrowserDevToolsEngineRequest) { requests.append(request) }
    func setDevToolsPlacement(_ placement: BrowserDevToolsPlacement) { placements.append(placement) }
    func setDevToolsFocused(_ focused: Bool) { focus.append(focused) }
}

@MainActor
private final class FakeDevToolsWindow: BrowserDevToolsWindowHosting {
    var onClose: (() -> Void)?
    var onFrameChange: ((CGRect) -> Void)?
    var title = ""
    private(set) var adopted: [NSView] = []
    private(set) var shown = 0
    private(set) var dismissed = 0

    func adopt(_ view: NSView) {
        view.removeFromSuperview()
        adopted.append(view)
    }
    func show() { shown += 1 }
    func dismiss() { dismissed += 1 }
    func contains(_ window: NSWindow) -> Bool { false }
}

@MainActor
@Suite struct BrowserDevToolsPaneControllerTests {
    @MainActor private struct Harness {
        let engine = FakeDevToolsEngine()
        let pane = BrowserDevToolsPaneView(pageView: NSView())
        let hostWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1001, height: 801), styleMask: [.titled], backing: .buffered, defer: true)
        let defaults: UserDefaults
        let suite: String
        let controller: BrowserDevToolsPaneController
        let windowBox: WindowBox

        @MainActor final class WindowBox {
            var made: [FakeDevToolsWindow] = []
            var remembered: [CGRect?] = []
        }

        init() {
            suite = "BrowserDevToolsPaneControllerTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            let box = WindowBox()
            windowBox = box
            controller = BrowserDevToolsPaneController(paneView: pane, store: BrowserDevToolsLayoutStore(defaults: defaults)) { _, remembered in
                box.remembered.append(remembered)
                let window = FakeDevToolsWindow()
                box.made.append(window)
                return window
            }
            controller.driver = engine
            pane.frame = CGRect(x: 0, y: 0, width: 1001, height: 801)
            hostWindow.contentView = pane
        }

        func open() {
            controller.engineWillOpenDevTools()
            controller.engineDidOpenDevTools(docked: true)
            pane.layoutSubtreeIfNeeded()
        }

        func host() -> NSView? {
            pane.subviews.first { $0.accessibilityIdentifier() == "browser.devtools.host" }
        }
    }

    @Test func toggleSendsShowThenClose() {
        let h = Harness()
        h.controller.perform(.toggle)
        #expect(h.engine.requests == [.show])
        h.open()
        h.controller.perform(.toggle)
        #expect(h.engine.requests == [.show, .close])
        h.controller.perform(.console)
        h.controller.perform(.inspect(x: 3, y: 4))
        #expect(h.engine.requests.suffix(2) == [.console, .inspectAt(x: 3, y: 4)])
    }

    @Test func openingDocksBelowThePageInsideThePane() throws {
        let h = Harness()
        var changes: [BrowserDevToolsState] = []
        h.controller.onStateChange = { state, _ in changes.append(state) }
        h.open()
        guard case .inView(let parent, _) = try #require(h.engine.placements.first) else {
            Issue.record("expected an in-view placement")
            return
        }
        let host = try #require(h.host())
        #expect(parent === host)
        #expect(host.frame == CGRect(x: 0, y: 0, width: 1001, height: 320))
        #expect(h.pane.pageView.frame == CGRect(x: 0, y: 321, width: 1001, height: 480))
        #expect(changes == [BrowserDevToolsState(isOpen: true, dock: .bottom)])
    }

    @Test func movingBetweenSidesKeepsTheSameHostAndRemembersTheDock() throws {
        let h = Harness()
        h.open()
        let host = try #require(h.host())
        h.controller.perform(.dock(.right))
        h.pane.layoutSubtreeIfNeeded()
        #expect(h.host() === host)
        #expect(host.frame == CGRect(x: 551, y: 0, width: 450, height: 801))
        #expect(h.controller.state == BrowserDevToolsState(isOpen: true, dock: .right))
        #expect(BrowserDevToolsLayoutStore(defaults: h.defaults).load().dock == .right)
        #expect(h.engine.requests.isEmpty)
    }

    @Test func undockingReparentsTheHostIntoTheWindowAndDockingBringsItBack() throws {
        let h = Harness()
        h.open()
        let host = try #require(h.host())
        h.controller.perform(.dock(.window))
        let window = try #require(h.windowBox.made.first)
        #expect(window.adopted.first === host)
        #expect(window.shown == 1)
        h.pane.layoutSubtreeIfNeeded()
        #expect(h.pane.pageView.frame == h.pane.bounds)
        h.controller.perform(.dock(.bottom))
        #expect(host.superview === h.pane)
        #expect(window.dismissed == 1)
        #expect(h.engine.requests.isEmpty)
    }

    @Test func enginesWithoutEmbeddedDevToolsReopenInTheirOwnWindow() throws {
        let h = Harness()
        h.engine.supportsEmbeddedDevTools = false
        h.controller.engineWillOpenDevTools()
        guard case .ownWindow = try #require(h.engine.placements.first) else {
            Issue.record("expected an own-window placement")
            return
        }
        h.controller.engineDidOpenDevTools(docked: false)
        #expect(h.controller.state == BrowserDevToolsState(isOpen: true, dock: .window))
        h.controller.perform(.dock(.bottom))
        #expect(h.engine.requests.isEmpty)
        #expect(h.controller.state == BrowserDevToolsState(isOpen: true, dock: .window))
        #expect(h.controller.layout.dock == .bottom)
    }

    @Test func closingRestoresThePageAndFrontendDockChoicesMove() throws {
        let h = Harness()
        h.open()
        // The frontend's first report on load is its saved preference; the pane's layout wins.
        h.controller.engineDidChooseDockSide(3)
        #expect(h.controller.state.dock == .bottom)
        h.controller.engineDidChooseDockSide(1)
        #expect(h.controller.state.dock == .left)
        h.controller.engineDidChooseDockSide(9)
        #expect(h.controller.state.dock == .left)
        h.controller.engineDidCloseDevTools()
        h.pane.layoutSubtreeIfNeeded()
        #expect(h.host() == nil)
        #expect(h.pane.pageView.frame == h.pane.bounds)
        #expect(h.controller.state == BrowserDevToolsState(isOpen: false, dock: .left))
    }

    @Test func anEngineWindowAfterADockedOfferLeavesNoEmptyArea() {
        let h = Harness()
        h.controller.engineWillOpenDevTools()
        h.controller.engineDidOpenDevTools(docked: false)
        h.pane.layoutSubtreeIfNeeded()
        #expect(h.host() == nil)
        #expect(h.pane.pageView.frame == h.pane.bounds)
        #expect(h.controller.state == BrowserDevToolsState(isOpen: true, dock: .window))
    }

    @Test func tearDownReportsTheCloseAndClosingWithoutAnEngineDropsTheViews() throws {
        let h = Harness()
        var changes: [BrowserDevToolsState] = []
        h.controller.onStateChange = { state, _ in changes.append(state) }
        h.open()
        h.controller.perform(.dock(.window))
        let window = try #require(h.windowBox.made.first)
        h.controller.driver = nil
        window.onClose?()
        #expect(window.dismissed == 1)
        #expect(!h.controller.state.isOpen)
        #expect(changes.last == BrowserDevToolsState(isOpen: false, dock: .window))
    }

    @Test func dockMenuListsChoicesWithTheCurrentOneChecked() {
        let h = Harness()
        h.open()
        let menu = BrowserDevToolsDockMenu(controller: h.controller).makeMenu()
        #expect(menu.items.count == 6)
        #expect(menu.items[1].state == .on)
        #expect(menu.items[0].state == .off)
        #expect(menu.items[4].isSeparatorItem)
        BrowserMenuActionTarget.target(of: menu.items[2])?.run(nil)
        #expect(h.controller.state.dock == .right)
        BrowserMenuActionTarget.target(of: menu.items[5])?.run(nil)
        #expect(h.engine.requests == [.close])
    }

    @Test func configureSetsTheDividerThicknessAndTheCloseShortcut() {
        let h = Harness()
        h.open()
        h.controller.configure(
            dividerThickness: 6,
            closeShortcut: BrowserDevToolsMenuShortcut(key: "i", modifiers: [.command, .option])
        )
        h.pane.layoutSubtreeIfNeeded()
        // 801 high: 795 available after the 6 pt line, 0.4 of it is 318; grab = line +/- 3.
        #expect(h.host()?.frame == CGRect(x: 0, y: 0, width: 1001, height: 318))
        #expect(h.pane.pageView.frame.minY == 324)
        let close = BrowserDevToolsDockMenu(controller: h.controller).makeMenu().items[5]
        #expect(close.keyEquivalent == "i")
        #expect(close.keyEquivalentModifierMask == [.command, .option])
    }

    @Test func undockedWindowsOpenAtTheRememberedFrameAndRememberMoves() throws {
        let h = Harness()
        BrowserDevToolsLayoutStore(defaults: h.defaults).saveWindowFrame(CGRect(x: 5, y: 6, width: 700, height: 500))
        h.open()
        h.controller.perform(.dock(.window))
        let window = try #require(h.windowBox.made.first)
        #expect(h.windowBox.remembered.first == CGRect(x: 5, y: 6, width: 700, height: 500))
        window.onFrameChange?(CGRect(x: 40, y: 50, width: 800, height: 600))
        #expect(BrowserDevToolsLayoutStore(defaults: h.defaults).loadWindowFrame() == CGRect(x: 40, y: 50, width: 800, height: 600))
    }

    @Test func windowTitlesFollowThePage() {
        #expect(BrowserDevToolsWindow.title(forPage: "  ").isEmpty == false)
        #expect(BrowserDevToolsWindow.title(forPage: "Example").contains("Example"))
    }
}
