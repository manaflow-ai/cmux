import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-19: "i did cmd n and started typing and it didnt have focus". On the cmux23 bench, "hello world 123"
/// typed at once after Cmd-N lost its first keys in 5 of 30 runs from a Chromium page ("lo world 123", "hllo world 123").
/// Every key reached the new New Tab page's Chromium window, held or typed, and its renderer dropped them: for a moment
/// after that window becomes key, a key event reaches no field. From the page's readiness until the Cmd-N hold's limit,
/// the window's keys go to the page by script instead (the key router's type-ahead, ``NewTabInputCoordinator/typesByScript(in:)``),
/// which needs no key window and no renderer focus. The held keys too: they run through the key router again at the drain.
@MainActor @Suite(.serialized)
struct CmdNScriptTypingTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "cmdn-ws"), name: "cmdn", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "cmdn-ws"), index: 0)])
        return tree
    }

    private static func key(_ character: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: character,
                                      charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
    }

    @Test func keysTypedFromCmdNsReadinessToItsHoldLimitGoToThePageByScript() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["cmdn-ws"], frame: CGRect(x: 200, y: 200, width: 1000, height: 700)))
        let folder = FileManager.default.temporaryDirectory.appending(path: "cmdn-chromium-\(UUID().uuidString)")
        let pageKey = "tab_cmdn_chromium_page"
        var view: AgentPaneView?
        defer {
            services.agentTabs.views[pageKey] = nil
            view?.close()
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: folder)
        }
        for _ in 0..<200 where controller.workspaceContent?.focusedPane == nil { try await Task.sleep(for: .milliseconds(10)) }
        let pane = try #require(controller.workspaceContent?.focusedPane, "the window never showed its workspace")
        let window = try #require(controller.window)

        // Cmd-N's new workspace page, in Chromium: a New Tab page whose window the grant has not made key yet.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "index.html")
        try Data("<html><body><textarea></textarea></body></html>".utf8).write(to: file)
        let hosting = FakeChromiumHosting()
        let made = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), newTab: AgentPaneNewTab(kind: .agent)), source: .bundled(file),
                                              pageHost: true, testRoot: true, chromium: hosting))
        view = made
        await made.page?.chromiumStart?.value
        _ = try #require(hosting.made.first, "the page did not start in Chromium")
        made.frame = pane.view.bounds
        pane.view.addSubview(made)
        services.agentTabs.views[pageKey] = made
        try #require(made.window === window && !made.isHiddenOrHasHiddenAncestor && made.chromiumPage != nil)

        // The hold Cmd-N opens, and a key typed right after it.
        let router = services.keyRouter, input = router.newTabInputCoordinator
        input.incomingHoldLimit = .seconds(4)
        input.scheduleDeadline = { _, _ in Task {} }
        var clock = ContinuousClock.now
        input.now = { clock }
        let token = try #require(input.beginIncoming(in: window))
        input.attachIncoming(token)
        #expect(router.interceptKeyDown(try Self.key("h", keyCode: 4, in: window), in: window), "the hold did not take the key")
        #expect(input.isHolding(in: window), "the hold let the key go before the page's readiness")

        // The page's field reports ready: the held key goes on, and keys go to the page by script from now on.
        input.pageReady(token, key: pageKey)
        #expect(input.log.contains { $0.hasPrefix("drained to field") }, "the held key did not go to the new page: \(input.log)")
        #expect(input.typesByScript(in: window), "keys typed after the readiness go to the page as key events, which its renderer drops")
        clock = clock.advanced(by: .seconds(3))
        #expect(input.typesByScript(in: window), "keys stopped going by script before the hold's limit")

        // The hold's limit passed: keys go their normal way again.
        clock = clock.advanced(by: .seconds(2))
        #expect(!input.typesByScript(in: window), "keys still go by script after the hold's limit")
    }
}
