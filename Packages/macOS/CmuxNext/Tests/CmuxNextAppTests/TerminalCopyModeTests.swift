import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCopyMode
import CmuxNextDaemon
@testable import CmuxNextTerminal
import Testing

/// Toggle Copy Mode (⇧⌘M) is bound and `/` routes to the find prompt. Both
/// hold without a Ghostty surface.
@MainActor
struct TerminalCopyModeBindingTests {
    @Test func toggleCopyModeIsBound() {
        let registry = ActionBindingCoverageTests.boundServices().registry
        #expect(registry.isBound("toggleTerminalCopyMode"))
        #expect(registry.unavailableReason(for: "toggleTerminalCopyMode") == nil)
    }

    @Test func slashOpensTheFindPrompt() {
        #expect(TerminalHostActionRoute.route(.find) == TerminalHostActionRoute.Route(id: "find"))
    }
}

@MainActor
private final class QuitMenuProbe: NSObject {
    var invocations = 0

    @objc func quit(_ sender: Any?) {
        invocations += 1
    }
}

/// Copy mode on a live surface: the action toggles it on the targeted
/// terminal, plain keys stay in it before the shell sees them, Command
/// chords pass through to app shortcuts, and q or Esc leaves. Needs
/// `ghostty_surface_new` to succeed (a Ghostty runtime and a Metal device);
/// the suite reports itself skipped where it cannot.
@MainActor
@Suite(.enabled("needs a live Ghostty surface") { await CopyModeLiveSurface.available() })
struct TerminalCopyModeTests {
    private static func terminal() throws -> (AppServices, TabModel, TerminalSurfaceView) {
        let view = try #require(CopyModeLiveSurface.make())
        return (view.services, view.tab, view.view)
    }

    private static func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    @Test func theActionTogglesCopyModeOnTheTargetedTerminal() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try BridgeTreeFixture.tree())
        let workspace = try #require(services.daemon.store.workspaces.first)
        let pane = try #require(workspace.screens.first?.panes.first)
        let tab = try #require(pane.tabs.first)
        let controller = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        defer { controller.window?.close() }
        await ReopenClosedTabTests.settle { services.paneController(for: pane) != nil }
        try #require(services.paneController(for: pane) != nil, "the window never showed the pane")
        let target = ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id))
        services.registry.context.insert(.terminalFocused)

        #expect(services.registry.perform("toggleTerminalCopyMode", invocation: target))
        let view = services.cache.terminal(for: tab, daemon: services.daemon).session.surfaceView
        #expect(view.isCopyModeActive)
        #expect(services.registry.perform("toggleTerminalCopyMode", invocation: target))
        #expect(!view.isCopyModeActive)
    }

    @Test func plainKeysStayInCopyModeAndQLeaves() throws {
        let (_, _, view) = try Self.terminal()
        #expect(view.toggleCopyMode())
        view.keyDown(with: try Self.key("j", keyCode: 38))
        view.keyDown(with: try Self.key("v", keyCode: 9))
        #expect(view.isCopyModeActive)
        #expect(view.copyMode.consumedKeyUps == [38, 9])
        view.keyDown(with: try Self.key("q", keyCode: 12))
        #expect(!view.isCopyModeActive)
        #expect(!view.hasSelection)
    }

    @Test func escapeLeavesAndKeyUpsAreSwallowed() throws {
        let (_, _, view) = try Self.terminal()
        #expect(view.toggleCopyMode())
        view.keyDown(with: try Self.key("\u{1b}", keyCode: 53))
        #expect(!view.isCopyModeActive)
        #expect(view.copyMode.handleKeyUp(try Self.key("\u{1b}", keyCode: 53)))
        #expect(!view.copyMode.handleKeyUp(try Self.key("\u{1b}", keyCode: 53)))
    }

    @Test func commandChordsPassThroughAndKeepTheMode() throws {
        let (_, _, view) = try Self.terminal()
        #expect(view.toggleCopyMode())
        view.copyMode.session?.input.countPrefix = 3
        #expect(!view.copyMode.handleKeyDown(try Self.key("c", keyCode: 8, flags: .command)))
        #expect(view.isCopyModeActive)
        #expect(view.copyMode.session?.input == CopyModeInputState())
        view.exitCopyMode()
    }

    @Test func commandQIsClaimedByTheAppBeforeTerminalForwarding() throws {
        #expect(KeyRouter.menuKeyEquivalentAllowedAfterDispatch(.system, eventWasDecided: true))
        let (services, _, view) = try Self.terminal()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(view))
        defer { window.close() }

        let probe = QuitMenuProbe()
        services.registry.unbind("quit")
        services.registry.bind("quit") { probe.invocations += 1 }
        services.registry.menuKeyEquivalentGate = { [weak services] id in
            services?.keyRouter.allowsMenuKeyEquivalent(id) ?? false
        }
        let menu = MainMenu.make(registry: services.registry)
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = previousMenu }

        let event = try Self.key("q", keyCode: 12, flags: [.command])
        // A real app dispatch marks the event before the terminal's
        // key-equivalent hook gets it. System actions must still be allowed
        // through the menu gate in that fallback path.
        services.keyRouter.decided.add(event)
        NSApp.sendEvent(event)
        #expect(probe.invocations == 1)
    }
}

/// A terminal on a fresh service graph, outside any window. Separate from
/// the suite so its `.enabled` trait can probe without naming the suite.
@MainActor
enum CopyModeLiveSurface {
    static func make() -> (services: AppServices, tab: TabModel, view: TerminalSurfaceView)? {
        let services = ActionBindingCoverageTests.boundServices()
        guard let tree = try? BridgeTreeFixture.tree() else { return nil }
        services.daemon.store.apply(snapshot: tree)
        guard let tab = services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first else { return nil }
        return (services, tab, services.cache.terminal(for: tab, daemon: services.daemon).session.surfaceView)
    }

    static func available() -> Bool {
        make()?.view.surface != nil
    }
}
