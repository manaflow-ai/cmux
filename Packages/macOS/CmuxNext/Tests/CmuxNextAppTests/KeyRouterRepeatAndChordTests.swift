import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// Two key router rules on a cmux window whose focused pane is a terminal (the real router, `interceptKeyDown`):
/// - a window or navigation shortcut pressed after an armed chord prefix it does not complete runs as itself:
///   Cmd-W after the Cmd-J leader closed nothing (it was dismissed; after another prefix it went to the view);
/// - a key-down the router already decided, sent again (a view re-sending a chord, a replayed dispatch), is not
///   decided a second time, so its action never runs twice; a new press of the same shortcut still runs.
@MainActor @Suite(.serialized)
struct KeyRouterRepeatAndChordTests {
    private struct Harness {
        let services: AppServices
        let shell: NSWindow
        var router: KeyRouter { services.keyRouter }
        func close() { for controller in services.windows.controllers { controller.window?.close() } }
    }

    private static func harness() throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)  // the catalog's actions and their default keys (Cmd-W: Close Tab)
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["repeat-workspace"]))
        let shell = try #require(controller.window)
        controller.focus.send(.topology(FocusTopology(workspace: "repeat-workspace", panes: [
            .init(id: "repeat-pane", tabs: [.init(id: "repeat-tab", kind: .terminal)], selected: "repeat-tab"),
        ])))
        controller.focus.send(.focusPane("repeat-pane", source: .keyboard))
        try #require(controller.focus.state.resolved == .terminal(pane: "repeat-pane", tab: "repeat-tab"))
        return Harness(services: services, shell: shell)
    }

    private static var timestamp: TimeInterval = 5000

    private static func key(_ characters: String, keyCode: UInt16, in harness: Harness) throws -> NSEvent {
        timestamp += 1
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: timestamp,
                                             windowNumber: harness.shell.windowNumber, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    /// The router's decision for `event`, dispatched as `sendEvent` does: whether it consumed the key.
    private static func dispatch(_ event: NSEvent, in harness: Harness) -> Bool {
        harness.router.dispatchingSynthetic(event) { harness.router.interceptKeyDown(event, in: harness.shell) }
    }

    @Test func aWindowShortcutAfterTheLeaderRunsAsItself() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let cmdW = try Self.key("w", keyCode: 13, in: harness)
        let resolved = try #require(harness.services.registry.resolveShortcut(for: cmdW), "Cmd-W is bound to nothing")
        try #require(resolved.tier != .content, "Cmd-W is a content shortcut here (\(resolved.id.rawValue))")

        #expect(Self.dispatch(try Self.key("j", keyCode: 38, in: harness), in: harness), "the Cmd-J leader did not arm")
        try #require(harness.router.chords.isPending, "the leader is not armed in a terminal")
        _ = Self.dispatch(cmdW, in: harness)
        #expect(harness.router.lastInterception?.action == resolved.id,
                "Cmd-W after the leader ran \(harness.router.lastInterception?.action.rawValue ?? "nothing") (want \(resolved.id.rawValue))")
        #expect(!harness.router.chords.isPending)
    }

    @Test func aDecidedKeySentAgainIsNotDecidedTwice() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let cmdW = try Self.key("w", keyCode: 13, in: harness)
        #expect(Self.dispatch(cmdW, in: harness), "the router did not take Cmd-W")
        let once = harness.router.interceptions
        #expect(!Self.dispatch(cmdW, in: harness), "the same key-down was taken again")
        #expect(harness.router.interceptions == once, "the same key-down ran its action twice")
        // A new press of the same shortcut is a new key-down: it runs.
        #expect(Self.dispatch(try Self.key("w", keyCode: 13, in: harness), in: harness))
        #expect(harness.router.interceptions > once && harness.router.lastInterception?.action != nil, "a second press of the same shortcut did not run")
    }
}
