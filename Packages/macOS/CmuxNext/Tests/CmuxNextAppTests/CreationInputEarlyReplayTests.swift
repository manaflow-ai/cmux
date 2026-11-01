import AppKit
@testable import CmuxNextFocusUI
import Foundation
import Testing

/// The creation hold's early and resolved paths against a host whose focus the test sets (review of #30094): held keys
/// go only to the new terminal while it has the keyboard, never past a replayed key that took the keyboard elsewhere,
/// and never into a composer that has the keyboard over the shown terminal.
@MainActor @Suite(.serialized)
struct CreationInputEarlyReplayTests {
    /// A host whose focus is a value the test sets; a replayed key may change it (a tab switch).
    private final class Host: CreationInputHost {
        var focus: CreationInputFocus
        var replayed: [String] = []
        var onReplay: ((NSEvent) -> Void)?
        init(focus: CreationInputFocus) { self.focus = focus }
        func creationShell(of window: NSWindow) -> NSWindow? { focus.shell }
        func creationFocus(in window: NSWindow) -> CreationInputFocus { focus }
        func isCloseKey(_ event: NSEvent, in shell: NSWindow) -> Bool { false }
        func replayHeldKey(_ event: NSEvent, in window: NSWindow) {
            replayed.append(event.charactersIgnoringModifiers ?? "")
            onReplay?(event)
        }
        func deliverGivenBack() {}
        var lastKeyAction: String? { nil }
    }

    private static func key(_ characters: String, _ flags: NSEvent.ModifierFlags = [], code: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private static func window() -> NSWindow {
        _ = NSApplication.shared
        return NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    }

    /// Cmd-D then Ctrl-2 onto a tab with no surface yet, then a letter, all held before the split's new terminal had the
    /// keyboard. When it takes the keyboard, Ctrl-2 runs first and moves the keyboard to tab 2 (its surface hold reuses
    /// this buffer and opens no creation): the letter and the key being judged keep waiting for tab 2, never run into
    /// the split's terminal or the window.
    @Test func earlyDeliveryStopsWhenAReplayedKeyMovesTheKeyboard() {
        let window = Self.window()
        let host = Host(focus: CreationInputFocus(shell: window, inContent: true, terminalTab: "split", takesKeys: false))
        let coordinator = CreationInputCoordinator()
        coordinator.host = host
        _ = coordinator.begin(in: window, generation: 1, earlyTab: "split", tab: "split")
        #expect(coordinator.capture(Self.key("2", .control, code: 19, in: window), in: window), "Ctrl-2 was not held")
        #expect(coordinator.capture(Self.key("l", code: 37, in: window), in: window), "the letter was not held")

        // The split's terminal has the keyboard; the replayed Ctrl-2 shows tab 2, whose surface is still to come.
        host.focus = CreationInputFocus(shell: window, inContent: true, terminalTab: "split", takesKeys: true,
                                        terminalHasKeyboard: true, terminalShown: true)
        host.onReplay = { event in
            guard event.modifierFlags.contains(.control) else { return }
            host.focus = CreationInputFocus(shell: window, inContent: true, terminalTab: "tab2", takesKeys: false)
        }
        let held = coordinator.capture(Self.key("s", code: 1, in: window), in: window)

        #expect(host.replayed == ["2"], "keys after the tab switch ran while tab 2 could not take them: \(host.replayed)")
        #expect(held, "the key after the tab switch went on with no terminal to take it")
        #expect(coordinator.heldCount(in: window) == 2, "the letter and the key do not both wait for tab 2")
    }

    /// Every creation replied, the focus names the new terminal shown in its pane, but an agent's composer over it has
    /// the keyboard: the next key does not end the hold into the composer.
    @Test func aResolvedHoldNeverEndsIntoAComposerOverTheShownTerminal() {
        let window = Self.window()
        // A composer is first responder: takesKeys (not a terminal view) but the shown terminal does not have the keyboard.
        let host = Host(focus: CreationInputFocus(shell: window, inContent: true, terminalTab: "new", takesKeys: true,
                                                  terminalHasKeyboard: false, terminalShown: true))
        let coordinator = CreationInputCoordinator()
        coordinator.host = host
        let ticket = coordinator.begin(in: window, generation: 1)
        #expect(coordinator.capture(Self.key("a", code: 0, in: window), in: window), "a key before the reply was not held")
        coordinator.resolve(ticket, landed: false, in: window)

        let held = coordinator.capture(Self.key("b", code: 11, in: window), in: window)

        #expect(host.replayed.isEmpty, "held keys typed for the new terminal ran into the composer: \(host.replayed)")
        #expect(held, "the key went on into the composer")
        #expect(coordinator.isHolding(in: window))
    }

    /// The same hold, once the shown terminal has the keyboard: the next key runs the held one first, then goes on.
    @Test func aResolvedHoldEndsAtTheKeyWhenTheShownTerminalHasTheKeyboard() {
        let window = Self.window()
        let host = Host(focus: CreationInputFocus(shell: window, inContent: true, terminalTab: "new", takesKeys: true,
                                                  terminalHasKeyboard: true, terminalShown: true))
        let coordinator = CreationInputCoordinator()
        coordinator.host = host
        let ticket = coordinator.begin(in: window, generation: 1)
        host.focus.terminalHasKeyboard = false
        #expect(coordinator.capture(Self.key("a", code: 0, in: window), in: window))
        coordinator.resolve(ticket, landed: false, in: window)
        host.focus.terminalHasKeyboard = true

        #expect(!coordinator.capture(Self.key("b", code: 11, in: window), in: window), "the key waited although the terminal has the keyboard")
        #expect(host.replayed == ["a"])
        #expect(!coordinator.isHolding(in: window))
    }
}
