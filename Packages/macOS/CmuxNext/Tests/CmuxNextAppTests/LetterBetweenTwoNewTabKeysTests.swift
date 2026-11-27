import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextControl
@testable import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextFocusUI
@testable import CmuxNextPages
import CmuxNextTestSupport
import Foundation
import Testing

/// New Tab key, a letter key, New Tab key: the app types the letter into the page of the first new tab. The letter
/// key and the second New Tab key come with no turn of the app between them.
///
/// The rule: a letter that is lost here is a fault. A person who holds New Tab and types gets each
/// letter in the tab of the New Tab key before it.
///
/// 2 rows. A New Tab page gets its view at the next frame of the app, for the tab that the pane has selected then,
/// and the pool of ready pages is empty here, so each page is made by that rule.
///
/// - The letter key comes after the first frame of the first new tab: the page of that tab has its view, and its
///   field is not ready at the letter key and not at the second New Tab key. At a key each 30 ms a frame comes
///   between 2 keys, so this is the state of a held New Tab key.
/// - The letter key comes before that frame: the first new tab has no page view at the letter key. The window's
///   creation hold then keeps the letter and the second New Tab key for that page, and gives them on when the page
///   has its view or at the hold's limit of 2 s. So the second New Tab key adds its tab later, not in its own call:
///   the test waits for that tab frame by frame. When the hold ended at its limit with no page view, the page of the
///   second new tab reports its field ready first; after that the pane selects the first new tab, its page gets its
///   view at the next frame, and its field reports ready.
///
/// A key that a hold gives on runs through the key router again, as in the app. The app's own call for it
/// (`NSApplication.sendEvent`) gives the key to the key window, and the window of a test is never the key window:
/// the test passes its own call to the services (`heldKeyReplay`), with the same way through the key router.
///
/// A frame is the app's own. The test waits for one by an event: a probe that stands in the presentation
/// scheduler's queue behind the pane. That wait does not poll and reads no clock. The wait of the second row for the
/// tab of a kept New Tab key is a count of frames with a sleep of 5 ms between 2 frames.
///
/// A whole window of the `large` session with no daemon. No creation is answered before the checks end. Each key is
/// a key-down event through the app's key router (`KeyRouter.interceptKeyDown`), as the app gets a key: none comes
/// from the system's event queue. No page loads: the test reports the field of the first new tab's page ready by the
/// call that the page's own message makes (`PageInputReadiness.receive`), and it reads what the app types into that
/// page at the one call by which the app types text into a page (`PageInputReadiness.editor`).
///
/// When the letter is lost, the message says where it went. The test reads the key router inside the second New Tab
/// key's call, at the router's own trace line for the key's decision: that line comes after the rule that a key with
/// Command ends the type-ahead queue, and before the key's action starts.
///
/// Limits. The test does not read the text of a field in a real page. A change that types the letter into the page
/// by another call needs another read in this test. The app keeps a letter for a page that is not ready for 2 s at
/// most: on a machine that stalls for 2 s between the letter key and the page's report, the test fails with and
/// without a mend.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct LetterBetweenTwoNewTabKeysTests {
    /// The creations of the test: each waits here, so none is answered before `release()`.
    @MainActor final class HeldCreations {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func wait() async {
            if released { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            released = true
            for one in waiting { one.resume() }
            waiting = []
        }
    }

    /// What the app typed into the page of the first new tab.
    @MainActor final class Typed {
        var edits: [PageInputReadiness.Edit] = []
    }

    /// The view that has the keyboard before the first key: it counts each key that it gets.
    final class KeyCount: NSView {
        var keys = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { keys += 1 }
    }

    /// The key router's state inside the second New Tab key's call, before the key's action starts.
    @MainActor final class BeforeTheAction {
        struct Reading {
            let queued: Bool
            let focusMoved: Bool
        }

        var read: (() -> Reading)?
        private(set) var first: Reading?

        func sample() {
            if first == nil, let read { first = read() }
        }
    }

    /// The keys of the test. Each key event has a time of its own: the key router tells two key events apart by it.
    @MainActor struct Keys {
        let router: KeyRouter
        let window: NSWindow
        private var stamp = ProcessInfo.processInfo.systemUptime

        init(router: KeyRouter, window: NSWindow) {
            self.router = router
            self.window = window
        }

        /// One key-down through the key router: the event, and if the router took the key.
        mutating func press(_ characters: String, code: UInt16, command: Bool) throws -> (event: NSEvent, took: Bool) {
            stamp += 0.03
            let made = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [], timestamp: stamp,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            let event = try #require(made, "setup: no key event could be made")
            let router = self.router, window = self.window
            return (event, router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) })
        }
    }

    /// Stands in the presentation scheduler's queue: its show is the event that a frame's drain ran. Its content is
    /// alive, so it spends nothing of the frame's budget, and it has no focus, so the focused pane shows before it.
    @MainActor final class FrameProbe: PresentablePane {
        var onShow: () -> Void = {}
        var selectedContentIsAlive: Bool { true }
        var isFocusedInWorkspace: Bool { false }
        func showSelected() { onShow() }
        func showWhileWaiting() {}
    }

    /// Returns when the app's next frame showed what waited for it.
    static func frame(_ services: AppServices) async {
        let probe = FrameProbe()
        await withCheckedContinuation { (shown: CheckedContinuation<Void, Never>) in
            probe.onShow = { shown.resume() }
            services.presentation.setNeedsShowSelected(probe)
        }
    }

    /// The page of the tab `key`, with the test's read of what the app types into it: nil when the tab has no page
    /// with a field.
    static func page(of key: String, in pane: PaneController, into typed: Typed) -> PageInputReadiness? {
        guard let page = pane.existingContent(for: key)?.inputReadiness else { return nil }
        page.editor = { edit, _ in
            typed.edits.append(edit)
            return true
        }
        return page
    }

    /// Where the key router's type-ahead queue has a letter now, in words. `first`: the page of the first new tab,
    /// when that tab has one.
    private static func queue(of router: KeyRouter, first: PageInputReadiness?) -> String {
        guard !router.typeAhead.text.isEmpty else { return "in no queue of the key router" }
        guard let first else { return "in the key router's queue for a page (the first new tab had no page view then)" }
        let own = router.typeAhead.surface == String(describing: ObjectIdentifier(first))
        return own ? "in the key router's queue for the page of the first new tab" : "in the key router's queue for another page"
    }

    /// What the test saw of the letter's way, for the message of a lost letter.
    private struct Way {
        /// The key router had marked the letter as decided while the window's key hold still had it.
        let decidedAtHold: Bool
        /// The key router's type-ahead code decided the letter in the second New Tab key's call.
        let decidedAfter: Bool
        /// At the second New Tab key the focus could queue typing for the page of the first new tab.
        let couldQueue: Bool
        let beforeTheAction: BeforeTheAction.Reading?
        let queuedAfterTheKey: Bool
        let queuedAfterTheTurn: Bool

        /// Which rule dropped the letter first, in words.
        var rule: String {
            guard !decidedAtHold else {
                return "The test does not say which rule dropped it: the key router had decided the letter before the hold gave it on."
            }
            guard decidedAfter else {
                return "The key router did not take the letter when the hold gave it on"
                    + (couldQueue ? "." : ": the focus could not queue typing for the page of the first new tab then.")
            }
            let took = "The key router took the letter when the hold gave it on"
            guard let beforeTheAction else {
                return took + ". The test got no trace line of the second key's decision, so it does not say which rule dropped the letter."
            }
            if !beforeTheAction.queued {
                let empty = took + ", and its queue was empty before the second key's action started"
                guard !beforeTheAction.focusMoved else {
                    return empty + ", after a focus move: the test does not say which rule dropped the letter first."
                }
                return empty + ", with the focus where it was before the key: "
                    + "the rule that a key with Command ends the type-ahead queue dropped the letter first."
            }
            if !queuedAfterTheKey {
                return took + ". Its queue had the letter when the second key's action started and not at the end of the key's call: "
                    + "the action dropped it."
            }
            if !queuedAfterTheTurn {
                return took + ". Its queue had the letter at the end of the second key's call and not after the app's next turn: "
                    + "the rule for a focus move dropped it first."
            }
            return took + ". Its queue had the letter until the page's report: the report did not type it."
        }
    }

    /// The letter key comes after the first frame of the first new tab.
    @Test func aLetterBetweenTwoNewTabKeysIsTypedIntoTheFirstNewTab() async throws {
        try await Self.aLetterBetweenTwoNewTabKeys(beforeTheFirstFrame: false)
    }

    /// The letter key comes before the first frame of the first new tab: that tab has no page view at the key.
    @Test func aLetterBeforeTheFirstFrameOfTheFirstNewTabIsTypedIntoThatTab() async throws {
        try await Self.aLetterBetweenTwoNewTabKeys(beforeTheFirstFrame: true)
    }

    private static func aLetterBetweenTwoNewTabKeys(beforeTheFirstFrame early: Bool) async throws {
        // An inert address for each New Tab page: the pages load nothing.
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        let givenOn = GivenOn()
        let services = Self.services(pages: environment, givenOn: givenOn)
        try await LargeSessionWindowFixture.withController(.large, services: services) { _, controller in
            let tabs = services.agentTabs
            try #require(tabs.canHostChat, "setup: this build has no New Tab page")
            let pane = try #require(controller.focusedPane, "setup: the window has no focused pane")
            let window = try #require(pane.view.window, "setup: the pane's view is in no window")
            let held = HeldCreations()
            tabs.localHost = AgentSessionRef.host(installID: "letter-between-two-new-tab-keys")
            tabs.holdsTabs = { _ in true }
            tabs.reachable = { _ in true }
            tabs.create = { _, _, _, _, _, _ in
                await held.wait()
                throw CancellationError()
            }
            // No ready page in the pool: each New Tab page of the test gets its view by the frame rule.
            let pool = services.newTabSpares
            pool.dropAll()
            pool.makeSpare = { _ in nil }
            let router = services.keyRouter
            let input = router.newTabInputCoordinator
            // The hold's limit is a time on the clock: it never passes in this test.
            let began = input.now()
            input.now = { began }
            input.scheduleDeadline = { _, _ in Task {} }
            let old = KeyCount(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            pane.view.addSubview(old)
            let hasKeyboard = window.makeFirstResponder(old) && window.firstResponder === old
            var keys = Keys(router: router, window: window)
            let seen = BeforeTheAction()
            let traceBefore = router.trace
            var failure: (any Error)?
            do {
                try #require(hasKeyboard, "setup: the test's view did not get the keyboard before the first key")

                // The first New Tab key.
                let start = Set(pane.orderedIDs.map(\.rawValue))
                let first = try keys.press("t", code: 17, command: true)
                try #require(first.took, "setup: the key router passed the first New Tab key on")
                let made = pane.orderedIDs.map(\.rawValue).filter { !start.contains($0) }
                try #require(made.count == 1, "setup: the first New Tab key added \(made.count) tabs to the strip in its own call, want 1")
                try #require(pane.existingContent(for: made[0])?.inputReadiness == nil,
                             "setup: the first new tab has a page with a field in the key's own call, with no ready page in the pool")
                let typed = Typed(), other = Typed()
                var page: PageInputReadiness?
                if !early {
                    // One frame of the app: the page of the first new tab gets its view.
                    await Self.frame(services)
                    let shown = try #require(Self.page(of: made[0], in: pane, into: typed),
                                             "setup: the first new tab has no page with a field after one frame of the app")
                    try #require(!shown.isReady, "setup: the field of the first new tab's page is ready after one frame, with no report")
                    page = shown
                }

                // The letter key: the window's key hold takes it.
                let letter = try keys.press("x", code: 7, command: false)
                try #require(letter.took && input.log.last?.hasPrefix("hold key #") == true,
                             "setup: the window's key hold did not take the letter key. The hold's log ends: \(input.log.suffix(6))")
                let decidedAtHold = router.decided.contains(letter.event)

                // The second New Tab key, in the same turn. The test reads the router at the trace line of the key's decision.
                let strip = Set(pane.orderedIDs.map(\.rawValue))
                let focusBefore = controller.focus.state.resolved
                let couldQueue = focusBefore.mayQueueTyping && page != nil && pane.currentContent?.inputReadiness === page
                seen.read = {
                    BeforeTheAction.Reading(queued: !router.typeAhead.text.isEmpty, focusMoved: controller.focus.state.resolved != focusBefore)
                }
                router.trace = { line in
                    if line.hasPrefix("dispatcher:") { seen.sample() }
                    traceBefore?(line)
                }
                // A hold can keep the second New Tab key and give it on later: the test then reads the router at that
                // time, from the focus of that time.
                givenOn.before = { event in
                    guard event.modifierFlags.contains(.command) else { return }
                    let focusThen = controller.focus.state.resolved
                    seen.read = {
                        BeforeTheAction.Reading(queued: !router.typeAhead.text.isEmpty, focusMoved: controller.focus.state.resolved != focusThen)
                    }
                }
                let second = try keys.press("t", code: 17, command: true)
                try #require(second.took, "setup: the key router passed the second New Tab key on")
                var more = pane.orderedIDs.map(\.rawValue).filter { !strip.contains($0) }
                var kept = ""
                if more.isEmpty {
                    let creation = router.creationInputCoordinator
                    try #require(creation.isHolding(in: window),
                                 """
                                 setup: the second New Tab key added no tab to the strip in its own call, and the window's creation hold \
                                 does not have the key (the window's key hold has keys: \(input.isHolding(in: window))). The key hold's \
                                 log ends: \(input.log.suffix(8))
                                 """)
                    // The creation hold ends at the page's view or at its own limit of 2 s. One turn of this wait is one frame.
                    var frames = 0
                    while more.isEmpty, frames < 2000 {
                        frames += 1
                        await Self.frame(services)
                        await LargeSessionWindowFixture.drainMain()
                        more = pane.orderedIDs.map(\.rawValue).filter { !strip.contains($0) }
                        if more.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
                    }
                    let end = creation.lastHoldEnd(in: window).map { String(describing: $0) } ?? "none"
                    kept = " The window's creation hold kept the letter and the second New Tab key, and the key added "
                        + "\(more.count) tabs after \(frames) frames (the hold still has keys: \(creation.isHolding(in: window)), "
                        + "its last end: \(end))."
                    if page == nil { page = Self.page(of: made[0], in: pane, into: typed) }
                    if page != nil { kept += " The first new tab had a page view when the test looked after that." }
                }
                router.trace = traceBefore
                seen.read = nil
                givenOn.before = { _ in }
                try #require(more.count == 1, "setup: the second New Tab key added \(more.count) tabs to the strip, want 1.\(kept)")
                let when = kept.isEmpty ? "directly after the second New Tab key" : "after the hold gave the second New Tab key on"
                let atKey = Self.queue(of: router, first: page)
                let queuedAfterTheKey = !router.typeAhead.text.isEmpty
                let decidedAfter = router.decided.contains(letter.event)
                let holdLog = input.log.suffix(8).joined(separator: " | ")

                // The app's next turn.
                await LargeSessionWindowFixture.drainMain()
                let afterTurn = Self.queue(of: router, first: page)
                let queuedAfterTheTurn = !router.typeAhead.text.isEmpty
                var state = early ? " The first new tab had no page view at the letter key and in the second New Tab key's own call." : ""
                state += kept
                if page == nil {
                    // One frame: the tab that the pane has selected (the second new tab) gets its page view, and its
                    // field reports ready first.
                    await Self.frame(services)
                    if let late = Self.page(of: more[0], in: pane, into: other) {
                        late.receive(true)
                        await LargeSessionWindowFixture.drainMain()
                        state += " The page of the second new tab reported its field ready before the first new tab had a page view."
                    } else {
                        state += " The second new tab had no page with a field after one frame."
                    }
                    // The pane selects the first new tab: its page gets its view at the next frame.
                    let tab = try #require(pane.orderedIDs.first { $0.rawValue == made[0] }, "setup: the first new tab is not in the strip")
                    pane.select(tab)
                    await Self.frame(services)
                    page = Self.page(of: made[0], in: pane, into: typed)
                }
                // The page of the first new tab reports its field ready.
                let field = try #require(
                    page, "setup: the first new tab has no page with a field after the pane selected it and one frame came")
                field.receive(true)
                try #require(field.isReady, "setup: the page of the first new tab is not ready after its report")
                await LargeSessionWindowFixture.drainMain()
                let got = typed.edits, gotOther = other.edits

                // The test still reads what the app types into the page.
                let reads = await field.insert("seam")
                try #require(reads && typed.edits.last == .insert("seam"), "setup: the test no longer reads what the app types into the page")

                let way = Way(decidedAtHold: decidedAtHold, decidedAfter: decidedAfter, couldQueue: couldQueue, beforeTheAction: seen.first,
                              queuedAfterTheKey: queuedAfterTheKey, queuedAfterTheTurn: queuedAfterTheTurn)
                #expect(old.keys == 0, "the view that had the keyboard before the first New Tab key got \(old.keys) keys, want 0")
                #expect(got == [.insert("x")],
                        """
                        the app typed \(got) into the page of the first new tab, want the letter one time.\(state) \(way.rule) The \
                        letter was \(atKey) \(when), and \(afterTurn) after the app's next turn. The app \
                        typed \(gotOther) into the page of the second new tab. The hold's log ends: \(holdLog)
                        """)
                #expect(gotOther.isEmpty,
                        "the app typed \(gotOther) into the page of the second new tab, want nothing: the letter is the first new tab's")
            } catch {
                failure = error
            }
            router.trace = traceBefore
            givenOn.before = { _ in }
            pool.makeSpare = nil
            // Each creation ends before the window closes.
            held.release()
            await LargeSessionWindowFixture.drainMain()
            if let failure { throw failure }
        }
    }
}
