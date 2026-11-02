import AppKit
@testable import CmuxNextFocusUI
import Foundation
import Testing

/// Cmd-D then Cmd-W from the Settings tab (macOS 15 tester, 2026-10-19): "does not work on the
/// first 2-3 tries and then ends up closing". The split's key hold kept every key, Cmd-W
/// included, until the new pane's focus landed. A split from a page tab opens a New Tab page, whose
/// focus is not the terminal focus the hold waits for, and a hold that had a creation never
/// expired. So each Cmd-W waited, and a later focus settle ran them all at once: the new tab, the
/// Settings tab and the window closed.
@MainActor @Suite struct CreationInputHoldTests {
    private static func key(_ characters: String, _ flags: NSEvent.ModifierFlags = [], code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private let cmdW = key("w", .command, code: 13)
    private let cmdV = key("v", .command, code: 9)
    private let letter = key("l", code: 37)

    /// A close key acts at once on what it closes (TabLifecycle cancels a pending creation); it never
    /// waits behind the creation to run after other keys.
    @Test func aCloseKeyIsNeverHeldBehindAPendingCreation() {
        let buffer = CreationInputBuffer(began: .now)
        _ = buffer.open(generation: 1)
        #expect(!buffer.holds(cmdW, limit: .seconds(2), expiring: true, closes: true))
        // Text and other chords (Cmd-V into the new terminal) still wait for it, in order.
        #expect(buffer.holds(letter, limit: .seconds(2), expiring: true, closes: false))
        #expect(buffer.holds(cmdV, limit: .seconds(2), expiring: true, closes: false))
    }

    /// The creation replied but the focus it asked for never landed (a New Tab page split): the hold
    /// ends at its limit, counted from the reply, instead of keeping the window's keys.
    @Test func aRepliedCreationStopsHoldingAtTheLimitEvenWhenItsFocusNeverLands() {
        let buffer = CreationInputBuffer(began: .now)
        let ticket = buffer.open(generation: 7)
        buffer.resolve(ticket, awaitsFocus: true)
        #expect(buffer.awaits(7))
        #expect(!buffer.holds(letter, limit: .zero, expiring: true, closes: false))
        // Within the limit after the reply, keys still wait for the focus.
        #expect(buffer.holds(letter, limit: .seconds(60), expiring: true, closes: false))
    }

    /// Until the reply, a creation keeps its keys whatever the limit (a slow daemon reply).
    @Test func aCreationWaitingForItsReplyKeepsItsKeys() {
        let buffer = CreationInputBuffer(began: .now - .seconds(30))
        _ = buffer.open(generation: 3)
        #expect(buffer.holds(letter, limit: .seconds(2), expiring: true, closes: false))
        #expect(buffer.hasPendingCreation)
    }

    /// Lawrence 2026-10-23: Cmd-D, type, Cmd-D, type, Cmd-W. The keys go to the pane the person saw
    /// when they typed them. The Cmd-W closes the second new pane before the daemon made it: the keys
    /// typed for it go with it, and the keys typed for the first new pane still wait for that pane.
    /// Before, the first pane got both, or (with no other creation pending) the close replayed them
    /// into whatever had the focus.
    @Test func closingAPendingCreationDropsOnlyTheKeysTypedForIt() {
        let buffer = CreationInputBuffer(began: .now)
        _ = buffer.open(generation: 1, tab: "first")
        let forFirst = Self.key("a", code: 0)
        buffer.capture(forFirst, focusedTab: "first")
        _ = buffer.open(generation: 2, tab: "second")
        buffer.capture(Self.key("b", code: 11), focusedTab: "second")
        #expect(buffer.cancel(tab: "second"))
        #expect(buffer.take() == [forFirst], "the keys typed for the closed pane went to another one")
    }

    /// A creation whose keys were all typed for it: its close drops them all; one that is not
    /// pending any more (its reply came) is not this hold's to cancel.
    @Test func aCreationIsCancelledOnlyWhileItIsPending() {
        let buffer = CreationInputBuffer(began: .now)
        let ticket = buffer.open(generation: 1, tab: "new")
        #expect(buffer.isCreating(tab: "new"))
        buffer.capture(Self.key("a", code: 0), focusedTab: "new")
        buffer.resolve(ticket, awaitsFocus: true)
        #expect(!buffer.isCreating(tab: "new"))
        #expect(!buffer.cancel(tab: "new"))
        #expect(buffer.take().count == 1, "a resolved creation's keys wait for its focus")
    }

    /// P0 1193 (re-review of #29693 at bc84781571b): a held Cmd-D that runs again at a hold's end opens a new hold with
    /// only that split's creation, and the keys typed after it for another terminal are carried into it (their own lane).
    /// The person closes that split before its reply: the keys typed for the split go with it, but the line carried for
    /// the other terminal stays and goes to that terminal. Before, the cancel found nothing waiting and dropped every key.
    @Test func closingAReplayOpenedSplitKeepsTheLineCarriedForAnotherTerminal() {
        let buffer = CreationInputBuffer(began: .now)
        _ = buffer.open(generation: 1, tab: "split")
        let forB = Self.key("b", code: 11), forSplit = Self.key("s", code: 1)
        let terminalA = CreationInputBuffer.HeldLane(tab: "terminalA", machine: nil)
        // The rest of the replay: a key of the issuing lane (it moves to the split) and a line for terminal B.
        buffer.prepend([(event: forSplit, lane: terminalA), (event: forB, lane: CreationInputBuffer.HeldLane(tab: "terminalB", machine: nil))],
                       issuer: terminalA)
        #expect(buffer.cancel(tab: "split"))
        #expect(buffer.take() == [forB], "the line carried for terminal B was dropped with the closed split (or the split's key was kept)")
    }
}
