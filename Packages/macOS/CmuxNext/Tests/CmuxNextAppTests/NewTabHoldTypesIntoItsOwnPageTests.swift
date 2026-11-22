import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// The New Tab key hold gives its keys to its own page, the one whose field took its readiness,
/// never to another page the window shows.
///
/// While cmux is not the active app no window is key. The replay sent a held key to the first
/// visible Chromium page window of the cmux window, which can be another pane's page (or the parked
/// spare), and Chromium drops a key sent to a page window that is not key. The fleet probe
/// (2026-11-21, P10) saw the first opening's key typed into another page while the opened field
/// stayed empty, and every later key kept by the router's type-ahead for a readiness the unfocused
/// document never reports: 0 of 24 first keys kept. The hold now names its ready page, and a held
/// key that types text goes into that page through its input bridge.
@MainActor @Suite(.serialized)
struct NewTabHoldTypesIntoItsOwnPageTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Stands in for the other page's Chromium page window: records every key event sent to it.
    private final class OtherPageWindow: NSWindow {
        var sent: [String] = []
        override func sendEvent(_ event: NSEvent) { if event.type == .keyDown { sent.append(event.characters ?? "") } }
    }

    /// One workspace, two panes side by side, each with one tab.
    private static func tree() -> DaemonTree {
        let first = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let layout: LayoutNode = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(first.id), b: .leaf(second.id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [first, second])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "own-page-ws"), name: "own page", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "own-page-ws"), index: 0)])
        return tree
    }

    private static func key(_ character: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: character,
                                      charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
    }

    /// A New Tab page shown in Chromium (a fake page whose focused element is an editable field).
    private static func chromiumNewTab(_ file: URL) async throws -> (AgentPaneView, FakeChromiumPage) {
        let hosting = FakeChromiumHosting()
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        model.becomeNewTab(AgentPaneNewTab(kind: .agent))
        let view = try #require(AgentPaneView(model: model, source: .bundled(file), pageHost: true, chromium: hosting))
        await view.page?.chromiumStart?.value
        let page = try #require(hosting.made.first, "no Chromium page was made")
        page.answer = { method, _ in method == "Runtime.evaluate" ? #"{"result":{"type":"boolean","value":true}}"# : nil }
        return (view, page)
    }

    /// The texts typed into a page's focused field through its input bridge, in order.
    private static func typed(_ page: FakeChromiumPage) -> [String] {
        page.calls.compactMap { call -> String? in
            guard call.method == "Runtime.evaluate", let expression = call.params["expression"] as? String,
                  let range = expression.range(of: "document.execCommand('insertText', false, ") else { return nil }
            let rest = expression[range.upperBound...]
            guard let end = rest.range(of: ");") else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(rest[..<end.lowerBound].utf8), options: [.fragmentsAllowed])) as? String
        }
    }

    @Test func heldKeysGoIntoTheHoldsOwnReadyPageNotAnotherShownPage() async throws {
        _ = NSApplication.shared
        try #require(!NSApp.isActive, "the test process is the active app: the person's path, where the page window is key")
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["own-page-ws"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        let directory = FileManager.default.temporaryDirectory.appending(path: "new-tab-own-page-\(UUID().uuidString)")
        var keys: [String] = []
        var views: [AgentPaneView] = []
        let otherWindow = OtherPageWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        otherWindow.isReleasedWhenClosed = false
        defer {
            for key in keys {
                services.agentTabs.views[key] = nil
                services.agentTabs.newTabPages[key] = nil
            }
            views.forEach { $0.close() }
            controller.window?.removeChildWindow(otherWindow)
            otherWindow.close()
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        try #require(content.panes.count == 2, "the window never showed the workspace's two panes")
        content.contentView.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        let models = try #require(store.workspaces.first?.screens.first?.panes)
        try #require(models.count == 2)
        let left = try #require(content.paneController(key: models[0].id))
        let right = try #require(content.paneController(key: models[1].id))
        for _ in 0..<100 where left.currentTabKey == nil || right.currentTabKey == nil { try await Task.sleep(for: .milliseconds(10)) }
        if left.currentTabKey == nil { left.showSelected() }
        if right.currentTabKey == nil { right.showSelected() }
        let otherKey = try #require(left.currentTabKey, "the left pane shows no tab")
        let ownKey = try #require(right.currentTabKey, "the right pane shows no tab")
        keys = [otherKey, ownKey]

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "index.html")
        try Data("<html><body><input></body></html>".utf8).write(to: file)
        // The left pane shows another New Tab page in Chromium, its field ready; its page window is a
        // visible child window of the cmux window.
        let (other, otherPage) = try await Self.chromiumNewTab(file)
        // The right pane shows the page the hold opened.
        let (own, ownPage) = try await Self.chromiumNewTab(file)
        views = [other, own]
        for (view, pane, key) in [(other, left, otherKey), (own, right, ownKey)] {
            view.frame = pane.view.bounds
            pane.view.addSubview(view)
            services.agentTabs.views[key] = view
            services.agentTabs.newTabPages[key] = (AgentPaneNewTab(kind: .agent),
                                                   NewTabPageHandler(open: { _, _ in }, jump: { _, _ in }, editShortcut: { _ in }))
            try #require(view.window === window && !view.isHiddenOrHasHiddenAncestor, "a page is not shown in the window")
        }
        let otherContent = otherPage.contentView
        otherWindow.setFrame(window.convertToScreen(otherContent.convert(otherContent.bounds, to: nil)), display: false)
        window.addChildWindow(otherWindow, ordered: .above)

        // The opening's hold, as NewTabPage.open begins it: only the field's readiness ends it here.
        let router = services.keyRouter
        let input = router.newTabInputCoordinator
        input.holdLimit = .seconds(600)
        input.scheduleDeadline = { _, _ in Task {} }
        let token = try #require(input.begin(for: right))
        input.didShow(in: window)
        let typed = [try Self.key("/", keyCode: 44, in: window), try Self.key("h", keyCode: 4, in: window), try Self.key("i", keyCode: 34, in: window)]
        for event in typed { #expect(router.interceptKeyDown(event, in: window), "the hold did not take \(event.characters ?? "")") }

        // The opened page's field reports ready: the held keys go into that page.
        input.acknowledge(token, in: window)
        #expect(!input.isHolding(in: window), "the hold kept the keys after the page's field was ready: \(input.log)")
        for _ in 0..<200 where Self.typed(ownPage).joined().count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(Self.typed(ownPage).joined() == "/hi", "the opened page's field got \(Self.typed(ownPage)) of the held keys: \(input.log)")
        #expect(Self.typed(otherPage).isEmpty, "the other shown page got the held keys \(Self.typed(otherPage))")
        #expect(otherWindow.sent.isEmpty, "the other page's window was sent the held keys \(otherWindow.sent)")
    }
}
