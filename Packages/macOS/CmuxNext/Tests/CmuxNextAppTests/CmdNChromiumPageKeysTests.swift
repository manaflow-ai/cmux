import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-19: "i did cmd n and started typing and it didnt have focus". The keys typed right after Cmd-N wait in
/// the window's New Tab hold (`NewTabInputCoordinator.beginIncoming`) and go on when the new page's field reports ready. A
/// New Tab page in Chromium takes the keyboard in its own child window, whose grant may wait for the page's first frame
/// (`CEFTab.grantFocus`). Until then the shell window is key with no responder: the hold ended at the readiness, so a key
/// typed in that gap reached no view (cmux23, run now-page-3: "hllo world 123").
///
/// After the drain, Cmd-N's workspace switch can also key the shell again for a moment (the same bench, now-page-8, with the
/// first fix: `contentPresented`, then `windowKey(true)`), and a key typed then was lost too.
///
/// The pass condition: until the hold's limit, every key typed in the window after the readiness still goes through the
/// hold and on at once, whether the page's window has the keys or not; at the limit the hold ends.
@MainActor @Suite(.serialized)
struct CmdNChromiumPageKeysTests {
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

    @Test func keysTypedAfterCmdNBeforeTheChromiumPageHasTheKeysStillReachIt() async throws {
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
        let chromium = try #require(hosting.made.first, "the page did not start in Chromium")
        made.frame = pane.view.bounds
        pane.view.addSubview(made)
        services.agentTabs.views[pageKey] = made
        try #require(made.window === window && !made.isHiddenOrHasHiddenAncestor && made.chromiumPage != nil)

        // The hold Cmd-N opens, and the keys typed right after it.
        let router = services.keyRouter, input = router.newTabInputCoordinator
        input.incomingHoldLimit = .seconds(4)
        input.scheduleDeadline = { _, _ in Task {} }
        var clock = ContinuousClock.now
        input.now = { clock }
        var reachNoView = true // the page's grant waits: the shell is key with no responder
        input.keysReachNoView = { _ in reachNoView }
        let token = try #require(input.beginIncoming(in: window))
        input.attachIncoming(token)
        let typed = try [("h", 4), ("e", 14), ("y", 16)].map { try Self.key($0.0, keyCode: $0.1, in: window) }
        for event in typed { #expect(router.interceptKeyDown(event, in: window), "the hold did not take \(event.characters ?? "")") }

        // The page's field reports ready: the held keys go on to it.
        input.pageReady(token, key: pageKey)
        #expect(chromium.focusAsks.contains(true), "the hold never asked the new page for the keyboard")
        #expect(input.log.contains { $0.hasPrefix("drained to field") }, "the held keys did not go to the new page: \(input.log)")

        // A key typed before the page's window has the keys: the hold still takes it and gives it on at once.
        let gap = try Self.key("o", keyCode: 31, in: window)
        #expect(router.interceptKeyDown(gap, in: window), "a key typed after the readiness, before the page had the keys, reached no view: \(input.log)")
        #expect(input.isHolding(in: window), "the hold ended while keys typed in the window reached no view: \(input.log)")

        // The page's window has the keys: the next key still goes through the hold, and on at once.
        reachNoView = false
        #expect(router.interceptKeyDown(try Self.key("u", keyCode: 32, in: window), in: window), "the hold did not pass the key on: \(input.log)")
        // The workspace switch keys the shell again: a key typed then still reaches the page through the hold.
        reachNoView = true
        #expect(router.interceptKeyDown(try Self.key("r", keyCode: 15, in: window), in: window),
                "a key typed while the switch keyed the shell again reached no view: \(input.log)")
        #expect(input.isHolding(in: window), "the hold ended before its limit: \(input.log)")

        // The hold's limit passes: the hold ends, and keys go their normal way.
        clock = clock.advanced(by: .seconds(5))
        input.flush(in: window)
        #expect(!input.isHolding(in: window), "the hold outlived its limit: \(input.log)")
    }
}
