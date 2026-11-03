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

    /// A new workspace's terminal asked for over Home (dogfood v2.2.3, ported from cp/dogfood-v2-2-12-opt f6646860fad3):
    /// its keys go on only once the window shows that workspace, and a failed creation or a workspace the window never
    /// shows takes them with it; they are never run into what has the focus instead (Home's Chief message box).
    @Test func keysTypedForANewWorkspacesTerminalGoOnlyToThatWorkspace() {
        let made = CreationInputBuffer(began: .now)
        let ticket = made.open(generation: 4, newWorkspace: true)
        #expect(made.newestGeneration == 4)
        made.capture(Self.key("e", code: 14), focusedTab: "home", forNewWorkspace: true)
        made.resolve(ticket, awaitsFocus: true, workspace: "ws-new")
        made.capture(Self.key("c", code: 8), focusedTab: "home", forNewWorkspace: true) // typed after the reply: still that terminal's
        #expect(made.awaitedWorkspace == "ws-new")
        #expect(made.dropKeys(ofWorkspacesOtherThan: "home"))
        #expect(made.take().isEmpty, "keys typed for the new terminal ran while the window showed Home")

        let shown = CreationInputBuffer(began: .now)
        let second = shown.open(generation: 5, newWorkspace: true)
        shown.capture(Self.key("e", code: 14), focusedTab: "home", forNewWorkspace: true)
        shown.resolve(second, awaitsFocus: true, workspace: "ws-new")
        #expect(!shown.dropKeys(ofWorkspacesOtherThan: "ws-new"))
        #expect(shown.take().count == 1, "the new workspace shows: its keys go to its terminal")

        let failed = CreationInputBuffer(began: .now)
        let third = failed.open(generation: 6, newWorkspace: true)
        failed.capture(Self.key("e", code: 14), focusedTab: "home", forNewWorkspace: true)
        failed.resolve(third, awaitsFocus: false)
        #expect(failed.awaitedWorkspace == nil)
        #expect(failed.take().isEmpty, "a failed new terminal's keys went to what had the focus")

        // A key typed after the person moved on (not for the new workspace) keeps its own route.
        let movedOn = CreationInputBuffer(began: .now)
        let fourth = movedOn.open(generation: 7, newWorkspace: true)
        movedOn.capture(Self.key("x", code: 7), focusedTab: "other", forNewWorkspace: false)
        movedOn.resolve(fourth, awaitsFocus: true, workspace: "ws-new")
        #expect(movedOn.dropKeys(ofWorkspacesOtherThan: "home"))
        #expect(movedOn.take().count == 1, "a key typed after the person moved on was dropped with the new workspace")
    }

    /// Review of #31865 (its merge with #31707): a key typed into a cold terminal opens that terminal's surface hold (an
    /// adopted lane). The person then asks for a new workspace in the same window. The keys typed after that, before the
    /// new workspace shows, are its terminal's, never the cold terminal's; the key typed before stays the cold terminal's.
    @Test func keysForAPersonsNewWorkspaceTypedDuringASurfaceHoldGoToTheNewTerminal() {
        let buffer = CreationInputBuffer(began: .now)
        buffer.awaitSurface(of: CreationInputBuffer.HeldLane(tab: "cold", machine: nil))
        buffer.capture(Self.key("a", code: 0), focusedTab: "cold")
        let ticket = buffer.open(generation: 9, newWorkspace: true)
        buffer.capture(Self.key("b", code: 11), focusedTab: "cold", forNewWorkspace: true)
        buffer.capture(Self.key("c", code: 8), focusedTab: "cold", forNewWorkspace: true)
        buffer.resolve(ticket, awaitsFocus: true, workspace: "ws-new")
        #expect(!buffer.dropKeys(ofWorkspacesOtherThan: "ws-new"))
        buffer.bindNewWorkspaceKeys(to: "new-terminal", machine: nil)
        let routed = buffer.take(focused: "new-terminal") { _, _ in false }.flatMap(\.keys)
            .map { "\($0.event.characters ?? "?"):\($0.lane?.tab ?? "-")" }
        #expect(routed == ["a:cold", "b:new-terminal", "c:new-terminal"],
                "keys typed for the person's new workspace went to the cold terminal, or a key was lost or reordered: \(routed)")
    }

    /// Review of #32148, note 2: two new workspaces in one hold, the first one's create failed, then the person acted (a
    /// click). The failed one is over, so the person left every creation of the hold: a key typed now is no workspace's
    /// (the focused view's at once, or a cold terminal's surface lane). Before, the failed id still counted, the hold
    /// never counted as left, and the keys waited without a lane to run as typed at its end, into the second workspace
    /// if that one showed by then.
    @Test func aFailedNewWorkspaceCountsAsLeftOnceThePersonActs() {
        let buffer = CreationInputBuffer(began: .now)
        let failed = buffer.open(generation: 1, newWorkspace: true)
        _ = buffer.open(generation: 2, newWorkspace: true)
        buffer.resolve(failed, awaitsFocus: false)
        #expect(!buffer.personLeftEveryCreation, "a failed workspace alone ended the person's hold before they acted")
        buffer.personMovedOn()
        #expect(buffer.personLeftEveryCreation, "after the click the failed workspace still kept the hold from counting as left")
        #expect(buffer.passesOn(focusedTab: nil), "a key typed after the click did not go on to the focused view")
    }

    /// Review of #32352 (note 2): Cmd-N (W1), type, click (W1 left), Cmd-N again (W2). Once the window shows W2 with its
    /// terminal, W1's kept keys no longer keep the hold open: the keys typed into W2 go on at once, and W1's keys go with
    /// the hold as before (dropped, its workspace is not the one shown). Before, they kept the hold up to its limit.
    @Test func aShownSecondWorkspaceEndsTheWaitForALeftOnesKeys() {
        let buffer = CreationInputBuffer(began: .now)
        let first = buffer.open(generation: 1, newWorkspace: true)
        buffer.capture(Self.key("a", code: 0), focusedTab: nil, forNewWorkspace: true)
        buffer.personMovedOn()
        let second = buffer.open(generation: 2, newWorkspace: true)
        buffer.resolve(first, awaitsFocus: true, workspace: "w1")
        buffer.resolve(second, awaitsFocus: true, workspace: "w2")
        #expect(buffer.shownWorkspaceToWaitFor == "w2")
        #expect(buffer.keysKeptForLeftWorkspace(shown: "w1-not-shown", terminalReady: true) != nil, "W1's keys must still wait while W2 is not shown")
        #expect(buffer.keysKeptForLeftWorkspace(shown: "w2", terminalReady: true) == nil,
                "W2 shows with its terminal, but W1's kept keys still hold the hold open (keys typed into W2 wait up to 2 s)")
    }

    /// Lead on STATUS 7828: a second ready-for-keys for a restored page (a page attached again, or another page's
    /// signal) never sends held keys twice or out of order. A page hold's keys are taken once at the ready signal (the
    /// coordinator's flush, which then drops the hold); keys typed after it are held only by a new hold, and go on at
    /// the next ready signal, after the first ones. The page receives every key once, in the order typed.
    @Test func twoReadySignalsWithKeysHeldBetweenThemDeliverEachKeyOnceInOrder() {
        let typed = "abcdef".map { Self.key(String($0), code: 0) }
        var page: [NSEvent] = []
        let first = CreationInputBuffer(began: .now)
        first.awaitContent(AwaitedContent(tab: "b", kind: .browser), machine: nil)
        typed[0..<3].forEach { first.capture($0, focusedTab: "b") }
        let ready = { (buffer: CreationInputBuffer) in page += buffer.take(focused: nil) { _, _ in false }.flatMap { $0.keys.map { $0.event } } }
        ready(first) // the first ready signal
        let second = CreationInputBuffer(began: .now) // the page is awaited again (attached again)
        second.awaitContent(AwaitedContent(tab: "b", kind: .browser), machine: nil)
        typed[3...].forEach { second.capture($0, focusedTab: "b") }
        ready(first) // a second signal for a hold already flushed: nothing again
        ready(second)
        ready(second)
        #expect(page.map(\.characters) == typed.map(\.characters), "the page got \(page.compactMap(\.characters).joined()), not abcdef")
        #expect(Set(page.map(ObjectIdentifier.init)).count == typed.count, "a held key went to the page twice")
    }
}
