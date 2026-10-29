import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import CmuxNextInput
import CmuxNextLaunch
import Testing

/// Every key a cmux path held and runs again goes through the one seam (``HeldKeyReplay``), so its hold is a measured
/// stage (held_by, hold ms) in `debug.input` (``HeldKeyReplay``): the New Tab field's replay and the
/// launch picture's replay and delivery each record their path.
@MainActor @Suite(.serialized)
struct HeldKeyReplayRoutingTests {
    private static var timestamp: TimeInterval = 13_000

    private static func key(_ characters: String, keyCode: UInt16, window: Int) throws -> NSEvent {
        timestamp += 0.01
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
                                             windowNumber: window, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    @Test func aKeyTheNewTabHoldRunsAgainRecordsItsHold() throws {
        _ = NSApplication.shared
        let router = KeyRouter(registry: ActionRegistry.standard())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let event = try Self.key("a", keyCode: 0, window: window.windowNumber)
        NewTabInputCoordinator.replay(event, held: event, in: window, router: router)
        #expect(router.heldKeys.stage(.newTab).count == 1, "the New Tab hold sent a key again without recording its hold")
    }

    @Test func keysTheLaunchPictureRunsAgainRecordTheirHold() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let router = services.keyRouter, keys = router.launchPictureKeys
        let id = "held-replay-picture-window"
        let picture = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        picture.isReleasedWhenClosed = false
        defer { picture.close() }
        keys.begin(window: id, shell: picture) { _ in }
        for (letter, code) in [("l", UInt16(37)), ("s", 1)] {
            let event = try Self.key(letter, keyCode: code, window: picture.windowNumber)
            #expect(router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: picture) })
        }
        #expect(keys.isHoldingUndecided(window: id))

        // The window's focus resolves: the router decides the two keys again, through the seam.
        let controller = try #require(services.windows.openWindow(id: id, workspaces: ["held-replay-ws"]))
        controller.focus.send(.topology(FocusTopology(workspace: "held-replay-ws", panes: [
            .init(id: "held-pane", tabs: [.init(id: "held-tab", kind: .terminal)], selected: "held-tab"),
        ])))
        controller.focus.send(.focusPane("held-pane", source: .keyboard))
        router.focusDidSettle(controller.focus.state, in: controller.window)
        #expect(!keys.isHoldingUndecided(window: id))
        let stage = router.heldKeys.stage(.launchPicture)
        #expect(stage.count == 2, "the launch picture ran \(stage.count) of 2 held keys through the seam")
        #expect(services.inputLatency.heldKeys === router.heldKeys, "the router records in another seam than debug.input reads")
    }
}
