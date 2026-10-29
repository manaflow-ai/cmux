import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextWakeups
import Foundation
import Testing

/// The key router's modes (`KeyRouterMode`): each owner that takes typing keys before the focused
/// view turns its mode on as it starts holding keys and off as it stops, and only then does the router ask it. In
/// normal mode a typing key goes straight to the focused view, with the outcome the full ordered walk gives it;
/// Escape and chords always take the walk.
@MainActor @Suite(.serialized)
struct KeyRouterModeTests {
    private struct Harness {
        let services: AppServices
        let controller: WindowController
        let shell: NSWindow
        var router: KeyRouter { services.keyRouter }
        var modes: KeyRouterModes { services.keyRouter.modes }
        func close() { for controller in services.windows.controllers { controller.window?.close() } }
    }

    private static func harness() throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["mode-workspace"]))
        let shell = try #require(controller.window)
        controller.focus.send(.topology(FocusTopology(workspace: "mode-workspace", panes: [
            .init(id: "mode-pane", tabs: [.init(id: "mode-tab", kind: .terminal)], selected: "mode-tab"),
        ])))
        controller.focus.send(.focusPane("mode-pane", source: .keyboard))
        try #require(controller.focus.state.resolved == .terminal(pane: "mode-pane", tab: "mode-tab"))
        return Harness(services: services, controller: controller, shell: shell)
    }

    private static var timestamp: TimeInterval = 9000

    private static func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], in harness: Harness) throws -> NSEvent {
        timestamp += 1
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                             windowNumber: harness.shell.windowNumber, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private static func plain(_ harness: Harness) throws -> NSEvent { try key("a", keyCode: 0, in: harness) }

    /// The router's decision for `event`, dispatched as `sendEvent` does: whether it consumed the key.
    private static func dispatch(_ event: NSEvent, in harness: Harness) -> Bool {
        harness.router.dispatchingSynthetic(event) { harness.router.interceptKeyDown(event, in: harness.shell) }
    }

    // MARK: Normal mode

    @Test func aFreshRouterIsInNormalModeAndATypingKeyGoesToTheFocusedView() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        #expect(harness.modes.isNormal, "modes on at launch: \(harness.modes.active)")
        var typedIn: [NSWindow?] = []
        harness.router.onTyping = { typedIn.append($0) }
        #expect(!Self.dispatch(try Self.plain(harness), in: harness), "the router took a typing key in normal mode")
        #expect(typedIn.count == 1 && typedIn.first.flatMap { $0 } === harness.shell, "the typing key was not noted for its window")
    }

    /// The fast path gives a typing key the outcome the ordered walk gives it: with a mode on whose owner is idle,
    /// the walk asks every owner and the key still goes to the focused view.
    @Test func normalModeAndTheOrderedWalkAgreeOnATypingKey() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        var typed = 0
        harness.router.onTyping = { _ in typed += 1 }
        let fast = Self.dispatch(try Self.plain(harness), in: harness)
        harness.modes.set(.windowHints, true)  // no session: every owner passes the key on
        let walked = Self.dispatch(try Self.plain(harness), in: harness)
        harness.modes.set(.windowHints, false)
        #expect(fast == walked && !fast, "normal mode consumed: \(fast), the ordered walk consumed: \(walked)")
        #expect(typed == 2, "the typing key reached the focused view \(typed) times in 2")
    }

    /// Escape is not a typing key: a missed sheet's Escape ends the sheet in normal mode too.
    @Test func escapeTakesTheOrderedWalkInNormalMode() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        var ended = 0
        harness.router.endTopmostSheet = { _ in
            ended += 1
            return true
        }
        try #require(harness.modes.isNormal)
        #expect(Self.dispatch(try Self.key("\u{1b}", keyCode: 53, in: harness), in: harness), "Escape did not end the missed sheet")
        #expect(ended == 1)
        // A typing key never asks for the sheet.
        _ = Self.dispatch(try Self.plain(harness), in: harness)
        #expect(ended == 1, "a typing key in normal mode asked the sheet seam")
    }

    // MARK: Each mode on and off

    @Test func theChordModeFollowsAnArmedChord() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        #expect(Self.dispatch(try Self.key("j", keyCode: 38, modifiers: [.command], in: harness), in: harness), "the Cmd-J leader did not arm")
        try #require(harness.router.chords.isPending, "the leader is not armed in a terminal")
        #expect(harness.modes.contains(.chord), "the chord mode is off while the leader waits")
        // The leader dismisses a stray letter: the typing key went to the chord, not the terminal.
        #expect(Self.dispatch(try Self.plain(harness), in: harness), "a typing key after the leader skipped the chord")
        #expect(!harness.router.chords.isPending)
        #expect(harness.modes.isNormal, "the chord mode stayed on after the chord ended: \(harness.modes.active)")

        _ = Self.dispatch(try Self.key("j", keyCode: 38, modifiers: [.command], in: harness), in: harness)
        #expect(harness.modes.contains(.chord))
        harness.router.cancelChord()
        #expect(harness.modes.isNormal, "cancelling the chord left its mode on")
    }

    @Test func theRecorderModeFollowsTheKeyboardShortcutsRecorder() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        var recorded = 0
        harness.router.keyRecorder = { _, _ in
            recorded += 1
            return true
        }
        #expect(harness.modes.contains(.recorder))
        #expect(Self.dispatch(try Self.plain(harness), in: harness), "the recorder did not get the typing key")
        #expect(recorded == 1)
        harness.router.keyRecorder = nil
        #expect(harness.modes.isNormal, "the recorder mode stayed on after recording stopped")
        #expect(!Self.dispatch(try Self.plain(harness), in: harness))
        #expect(recorded == 1, "a typing key reached the recorder after it stopped")
    }

    @Test func theFocusModeEscapeModeFollowsTheArmedExit() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        _ = harness.router.focusModeEscape.handle(isPlainEscape: true, isRepeat: false, timestamp: 1, focusModeTab: "mode-tab")
        #expect(harness.modes.contains(.focusModeEscape), "the armed exit left its mode off")
        // Any other key disarms the exit; it takes the walk to do so.
        _ = Self.dispatch(try Self.plain(harness), in: harness)
        #expect(harness.router.focusModeEscape.armedTab == nil, "a typing key did not disarm the exit")
        #expect(harness.modes.isNormal, "the exit's mode stayed on once disarmed: \(harness.modes.active)")
    }

    @Test func theNewTabCaptureModeFollowsTheNewTabHold() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let input = harness.router.newTabInputCoordinator
        input.scheduleDeadline = { _, _ in DemandTimer(owner: "test.holdLimit") }
        let token = try #require(input.beginIncoming(in: harness.shell))
        #expect(harness.modes.contains(.newTabCapture), "the New Tab hold left its mode off")
        #expect(Self.dispatch(try Self.plain(harness), in: harness), "the New Tab hold did not take the typing key")
        input.endIncoming(token, pageMade: false)
        #expect(!input.isHolding(in: harness.shell))
        #expect(harness.modes.isNormal, "the New Tab hold's mode stayed on after it ended: \(harness.modes.active)")
    }

    @Test func theCreationCaptureModeFollowsTheCreationHold() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let input = harness.router.creationInputCoordinator
        input.holdUntilShown(in: harness.shell)
        #expect(harness.modes.contains(.creationCapture), "the creation hold left its mode off")
        #expect(Self.dispatch(try Self.plain(harness), in: harness), "the creation hold did not take the typing key")
        // Past its limit the hold ends at the next key: its keys go on and the mode goes off.
        input.holdLimit = .zero
        _ = Self.dispatch(try Self.plain(harness), in: harness)
        #expect(harness.modes.isNormal, "the creation hold's mode stayed on after it ended: \(harness.modes.active)")
    }

    @Test func theWindowHintsModeFollowsClickByHint() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let content = try #require(harness.shell.contentView)
        let button = NSButton(title: "Hint target", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 20, width: 120, height: 32)
        content.addSubview(button)
        let hints = harness.services.windowHints
        hints.toggle(in: harness.controller)
        try #require(hints.isActive, "Click by Hint showed no labels over a window with a button")
        #expect(harness.modes.contains(.windowHints), "Click by Hint left its mode off")
        hints.cancel()
        #expect(harness.modes.isNormal, "Click by Hint's mode stayed on after it ended: \(harness.modes.active)")
    }

    @Test func theLinkHintsModeFollowsALinkHintSession() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let root = FileManager.default.temporaryDirectory.appending(path: "key-router-mode-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(LinkHintShim.symbol), storage: CEFProfileStorage(root: root))
        // A tab's scheduled work reads the runtime through an unowned reference: it outlives the test.
        _ = Unmanaged.passRetained(runtime)
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        let hints = harness.services.linkHints
        hints.start(.follow, tab: tab, window: harness.shell, isFocused: { true }, openInSplit: { _ in }, notice: { _ in })
        try #require(hints.isActive)
        #expect(harness.modes.contains(.linkHints), "link hints left their mode off")
        hints.cancel()
        #expect(harness.modes.isNormal, "the link hints mode stayed on after they ended: \(harness.modes.active)")
    }
}

/// Stand-in shim: every symbol does nothing and returns 0 (Chromium never starts).
private nonisolated enum LinkHintShim {
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let nothing: @convention(c) () -> Int = { 0 }
        return unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
    }
}
