import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextFocusUI
@testable import CmuxNextPages
import CmuxNextTestSupport
import Foundation
import Testing

/// New Tab key, a letter key, New Tab key, with no turn of the app between them: the app types the letter into the
/// page of the first new tab. The field of that page is not ready at the letter key and not at the second New Tab
/// key.
///
/// Decision of 2026-11-17: a letter that is lost here is a fault. A person who holds New Tab and types gets each
/// letter in the tab of the New Tab key before it.
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
    @MainActor private final class HeldCreations {
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
    @MainActor private final class Typed {
        var edits: [PageInputReadiness.Edit] = []
    }

    /// The view that has the keyboard before the first key: it counts each key that it gets.
    private final class KeyCount: NSView {
        var keys = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { keys += 1 }
    }

    /// The key router's state inside the second New Tab key's call, before the key's action starts.
    @MainActor private final class BeforeTheAction {
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
    @MainActor private struct Keys {
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

    /// Where the key router's type-ahead queue has a letter now, in words.
    private static func queue(of router: KeyRouter, page: PageInputReadiness) -> String {
        guard !router.typeAhead.text.isEmpty else { return "in no queue of the key router" }
        let own = router.typeAhead.surface == String(describing: ObjectIdentifier(page))
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

    @Test func aLetterBetweenTwoNewTabKeysIsTypedIntoTheFirstNewTab() async throws {
        // An inert address for each New Tab page: the pages load nothing.
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        try await LargeSessionWindowFixture.withController(.large, agentPaneEnvironment: environment) { _, controller in
            let services = controller.services
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
                let page = try #require(pane.existingContent(for: made[0])?.inputReadiness, "setup: the first new tab has no page with a field")
                try #require(!page.isReady, "setup: the field of the first new tab's page is ready in the key's own call")
                let typed = Typed()
                page.editor = { edit, _ in
                    typed.edits.append(edit)
                    return true
                }

                // The letter key, before the app's next turn: the window's key hold takes it.
                let letter = try keys.press("x", code: 7, command: false)
                try #require(letter.took && input.log.last?.hasPrefix("hold key #") == true,
                             "setup: the window's key hold did not take the letter key. The hold's log ends: \(input.log.suffix(6))")
                let decidedAtHold = router.decided.contains(letter.event)

                // The second New Tab key, in the same turn. The test reads the router at the trace line of the key's decision.
                let strip = Set(pane.orderedIDs.map(\.rawValue))
                let focusBefore = controller.focus.state.resolved
                let couldQueue = focusBefore.mayQueueTyping && pane.currentContent?.inputReadiness === page
                seen.read = {
                    BeforeTheAction.Reading(queued: !router.typeAhead.text.isEmpty, focusMoved: controller.focus.state.resolved != focusBefore)
                }
                router.trace = { line in
                    if line.hasPrefix("dispatcher:") { seen.sample() }
                    traceBefore?(line)
                }
                let second = try keys.press("t", code: 17, command: true)
                router.trace = traceBefore
                seen.read = nil
                try #require(second.took, "setup: the key router passed the second New Tab key on")
                let more = pane.orderedIDs.map(\.rawValue).filter { !strip.contains($0) }
                try #require(more.count == 1, "setup: the second New Tab key added \(more.count) tabs to the strip in its own call, want 1")
                let atKey = Self.queue(of: router, page: page)
                let queuedAfterTheKey = !router.typeAhead.text.isEmpty
                let decidedAfter = router.decided.contains(letter.event)
                let holdLog = input.log.suffix(8).joined(separator: " | ")

                // The app's next turn, then the page of the first new tab reports its field ready.
                await LargeSessionWindowFixture.drainMain()
                let afterTurn = Self.queue(of: router, page: page)
                let queuedAfterTheTurn = !router.typeAhead.text.isEmpty
                page.receive(true)
                try #require(page.isReady, "setup: the page of the first new tab is not ready after its report")
                await LargeSessionWindowFixture.drainMain()
                let got = typed.edits

                // The test still reads what the app types into the page.
                let reads = await page.insert("seam")
                try #require(reads && typed.edits.last == .insert("seam"), "setup: the test no longer reads what the app types into the page")

                let way = Way(decidedAtHold: decidedAtHold, decidedAfter: decidedAfter, couldQueue: couldQueue, beforeTheAction: seen.first,
                              queuedAfterTheKey: queuedAfterTheKey, queuedAfterTheTurn: queuedAfterTheTurn)
                #expect(old.keys == 0, "the view that had the keyboard before the first New Tab key got \(old.keys) keys, want 0")
                #expect(got == [.insert("x")],
                        """
                        the app typed \(got) into the page of the first new tab, want the letter one time. \(way.rule) The letter was \
                        \(atKey) directly after the second New Tab key, and \(afterTurn) after the app's next turn. The hold's log ends: \
                        \(holdLog)
                        """)
            } catch {
                failure = error
            }
            router.trace = traceBefore
            // Each creation ends before the window closes.
            held.release()
            await LargeSessionWindowFixture.drainMain()
            if let failure { throw failure }
        }
    }
}
