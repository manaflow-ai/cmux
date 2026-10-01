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

/// Copy mode on a live surface: the action toggles it on the targeted
/// terminal, plain keys stay in it before the shell sees them, Command
/// chords pass through to app shortcuts, and q or Esc leaves. Needs
/// `ghostty_surface_new` to succeed (a Ghostty runtime and a Metal device);
/// the suite reports itself skipped where it cannot.
@MainActor
@Suite(.enabled("needs a live Ghostty surface") { await TerminalCopyModeTests.liveSurfaceAvailable() })
struct TerminalCopyModeTests {
    static func liveSurfaceAvailable() -> Bool {
        (try? terminal())?.2.surface != nil
    }

    private static func terminal() throws -> (AppServices, TabModel, TerminalSurfaceView) {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try BridgeTreeFixture.tree())
        let tab = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        let view = services.cache.terminal(for: tab, daemon: services.daemon).session.surfaceView
        return (services, tab, view)
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
        #expect(view.copyModeConsumedKeyUps == [38, 9])
        view.keyDown(with: try Self.key("q", keyCode: 12))
        #expect(!view.isCopyModeActive)
        #expect(!view.hasSelection)
    }

    @Test func escapeLeavesAndKeyUpsAreSwallowed() throws {
        let (_, _, view) = try Self.terminal()
        #expect(view.toggleCopyMode())
        view.keyDown(with: try Self.key("\u{1b}", keyCode: 53))
        #expect(!view.isCopyModeActive)
        #expect(view.handleCopyModeKeyUp(try Self.key("\u{1b}", keyCode: 53)))
        #expect(!view.handleCopyModeKeyUp(try Self.key("\u{1b}", keyCode: 53)))
    }

    @Test func commandChordsPassThroughAndKeepTheMode() throws {
        let (_, _, view) = try Self.terminal()
        #expect(view.toggleCopyMode())
        view.copyMode?.input.countPrefix = 3
        #expect(!view.handleCopyModeKeyDown(try Self.key("c", keyCode: 8, flags: .command)))
        #expect(view.isCopyModeActive)
        #expect(view.copyMode?.input == CopyModeInputState())
        view.exitCopyMode()
    }
}
