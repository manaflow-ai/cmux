import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A person presses Cmd-T, types a line with Return before the New Tab page's field is ready, and closes
/// the page. The window's key hold (`NewTabInputCoordinator`) has the line.
///
/// - Closed by the Close Tab ACTION (the menu, the Commands palette, the CLI), the shared drop
///   (`CreationInputCoordinator.drop(tab:in:)`) discards the held keys: they go with the page.
/// - Closed by the Cmd-W KEY, the hold's chord rule ran first: it ended the hold and gave the held keys to
///   what had the keyboard, before the close ran. Until the page's field takes the keyboard, that is the
///   view that had it before Cmd-T: a terminal. So the line ran in a terminal the person did not type it in.
///
/// The view that has the keyboard here is a probe that stands for that terminal. Both closes must give it
/// no key.
@MainActor @Suite(.serialized)
struct NewTabHoldCloseKeyTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Stands for the terminal that had the keyboard before Cmd-T: it records each key it gets.
    private final class KeyProbe: NSView {
        var typed = ""
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { typed += event.characters ?? "" }
    }

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "hold-close-ws"), name: "hold", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "hold-close-ws"), index: 0)])
        return tree
    }

    private static func key(_ character: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: character,
                                      charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
    }

    /// One window with one pane that shows a New Tab page whose field is not ready, the hold of its opening
    /// with the line `ls` and Return in it, and the probe with the keyboard. `body` closes the page.
    private static func withAHeldLine(_ body: (AppServices, NSWindow, PaneController, String, KeyProbe) throws -> Void) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["hold-close-ws"], frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        let directory = FileManager.default.temporaryDirectory.appending(path: "new-tab-hold-close-\(UUID().uuidString)")
        var pageKey: String?
        defer {
            if let pageKey {
                services.agentTabs.views[pageKey] = nil
                services.agentTabs.newTabPages[pageKey] = nil
            }
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        try #require(content.panes.count == 1, "the window never showed the workspace's pane")
        content.contentView.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        let pane = try #require(content.panes.values.first)
        for _ in 0..<100 where pane.currentTabKey == nil { try await Task.sleep(for: .milliseconds(10)) }
        if pane.currentTabKey == nil { pane.showSelected() }
        let key = try #require(pane.currentTabKey, "the pane shows no tab")
        pageKey = key

        // The pane's tab is a New Tab page whose field has not reported ready.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "index.html")
        try Data("<html><body><input></body></html>".utf8).write(to: file)
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        model.becomeNewTab(AgentPaneNewTab(kind: .agent))
        let page = try #require(AgentPaneView(model: model, source: .bundled(file)))
        page.frame = pane.view.bounds
        pane.view.addSubview(page)
        services.agentTabs.views[key] = page
        services.agentTabs.newTabPages[key] = (AgentPaneNewTab(kind: .agent),
                                               NewTabPageHandler(open: { _, _ in }, jump: { _, _ in }, editShortcut: { _ in }))
        try #require(page.window === window && !page.isHiddenOrHasHiddenAncestor, "the page is not shown in the window")

        // The view that had the keyboard before Cmd-T still has it.
        let probe = KeyProbe(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        content.contentView.addSubview(probe)
        try #require(window.makeFirstResponder(probe) && window.firstResponder === probe, "the probe did not get the keyboard (first responder \(String(describing: window.firstResponder)))")

        // The opening's hold, as NewTabPage.open begins it, and the line typed before the field is ready.
        let router = services.keyRouter
        let input = router.newTabInputCoordinator
        input.holdLimit = .seconds(600)
        input.scheduleDeadline = { _, _ in Task {} }
        _ = try #require(input.begin(for: pane))
        input.didShow(in: window)
        let line = [try key("l", keyCode: 37, in: window), try key("s", keyCode: 1, in: window), try key("\r", keyCode: 36, in: window)]
        for event in line { try #require(router.interceptKeyDown(event, in: window), "the hold did not take a key of the line: \(input.log)") }
        try #require(input.isHolding(in: window) && probe.typed.isEmpty, "the line is not held: probe \"\(probe.typed)\", \(input.log)")
        try #require(window.firstResponder === probe, "the keyboard left the probe before the close (first responder \(String(describing: window.firstResponder)))")

        try body(services, window, pane, key, probe)
    }

    @Test func aLineHeldForANewTabPageGoesToNoTerminalWhenTheCmdWKeyClosesThePage() async throws {
        try await Self.withAHeldLine { services, window, _, _, probe in
            let input = services.keyRouter.newTabInputCoordinator
            let close = try Self.key("w", keyCode: 13, flags: .command, in: window)
            let resolved = services.registry.resolveShortcut(for: close)?.id
            try #require(resolved == "closeTab", "Cmd-W does not resolve to Close Tab here (\(String(describing: resolved))): this run proves nothing")
            // The step of `KeyRouter.interceptKeyDown` that runs before the key's action. The action itself
            // does not run here: the store of this test has no daemon to close the tab.
            #expect(!input.capture(close, in: window), "the hold took the Cmd-W key itself")
            #expect(!input.isHolding(in: window), "the hold did not end at the chord: \(input.log)")
            #expect(probe.typed.isEmpty, "the line typed for the New Tab page went to the view that had the keyboard before Cmd-T: \"\(probe.typed)\" (hold log \(input.log))")
        }
    }

    @Test func aLineHeldForANewTabPageGoesToNoTerminalWhenTheCloseTabActionClosesThePage() async throws {
        try await Self.withAHeldLine { services, window, _, key, probe in
            let input = services.keyRouter.newTabInputCoordinator
            // What `TabLifecycle.close` and `PaneCommands` run for a page that closes before the daemon made it.
            services.keyRouter.creationInputCoordinator.drop(tab: key, in: window)
            #expect(!input.isHolding(in: window), "the hold did not end at the close: \(input.log)")
            #expect(probe.typed.isEmpty, "the line typed for the New Tab page went to the view that had the keyboard before Cmd-T: \"\(probe.typed)\" (hold log \(input.log))")
        }
    }

    /// The chord rule stays for every other chord: keys typed ahead of Cmd-V go on first.
    @Test func aChordThatClosesNothingStillSendsTheHeldLineOnFirst() async throws {
        try await Self.withAHeldLine { services, window, _, _, probe in
            let input = services.keyRouter.newTabInputCoordinator
            let paste = try Self.key("v", keyCode: 9, flags: .command, in: window)
            #expect(!input.capture(paste, in: window), "the hold took the Cmd-V key itself")
            #expect(!input.isHolding(in: window), "the hold did not end at the chord: \(input.log)")
            #expect(input.log.contains { $0.hasPrefix("release: chord, keys") }, "the keys typed ahead of Cmd-V did not go on: \(input.log)")
        }
    }
}
