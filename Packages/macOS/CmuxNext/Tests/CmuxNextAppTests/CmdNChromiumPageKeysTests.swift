import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-19: "i did cmd n and started typing and it didnt have focus". The keys typed right after Cmd-N wait in
/// the window's New Tab hold (`NewTabInputCoordinator.beginIncoming`) and go on when the new page's field reports ready.
/// A New Tab page in Chromium takes the keyboard in its own child window, and its focus grant may wait (a page shown in
/// this turn, its first frame out of the window: `CEFTab.grantFocus` keeps the ask). The hold still counted the field as
/// focused the moment it asked, so it gave the held keys on at once to the window that had them then: the old page's
/// Chromium window, or the shell with no responder. The new field got none of them.
///
/// The pass condition: until the new page's window has the keys, no held key leaves the hold; once it has them, every
/// held key goes to it, in order.
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

    @Test func keysTypedAfterCmdNWaitUntilTheNewChromiumPageHasTheKeys() async throws {
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
        input.incomingHoldLimit = .seconds(600)
        input.scheduleDeadline = { _, _ in Task {} }
        let token = try #require(input.beginIncoming(in: window))
        input.attachIncoming(token)
        let typed = try [("h", 4), ("e", 14), ("y", 16)].map { try Self.key($0.0, keyCode: $0.1, in: window) }
        for event in typed { #expect(router.interceptKeyDown(event, in: window), "the hold did not take \(event.characters ?? "")") }

        // The page's field reports ready; its window does not have the keys yet (the grant waits for its first frame).
        chromium.hasKeys = false
        input.pageReady(token, key: pageKey)
        #expect(chromium.focusAsks.contains(true), "the hold never asked the new page for the keyboard")
        let lost = input.log.contains { $0.hasPrefix("drained to field") } ? typed.count : 0
        #expect(lost == 0, "\(lost) of \(typed.count) keys typed after Cmd-N left the hold before the new page had the keys: \(input.log)")
        #expect(input.isHolding(in: window), "the hold ended before the new page's window had the keys: \(input.log)")

        // The grant lands: the page's window has the keys, and every held key goes to it.
        chromium.hasKeys = true
        input.flush(in: window)
        #expect(!input.isHolding(in: window), "the hold kept the keys after the new page had the keyboard: \(input.log)")
        #expect(input.log.contains { $0.hasPrefix("drained to field") }, "the held keys did not go to the new page: \(input.log)")
    }
}
