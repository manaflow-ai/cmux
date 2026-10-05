import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// Typing into a page that has not loaded (spec app-screens.md section 3,
/// R59): printable keys for a page surface whose document is not ready are
/// queued in order, bounded (256 characters, 2 s), and delivered to the
/// primary input when the page reports it ready; a Command or Control chord,
/// a focus move or the timeout drops the queue; shortcuts resolve first.
@MainActor
struct PageTypeAheadTests {
    typealias M = KeyOwnershipMatrixTests
    typealias K = KeyInterceptionTests

    static let loading = KeyRouter.Facts(pageInputPending: true)

    @Test func printableKeysOnALoadingPageAreQueuedAndChordsStillResolve() throws {
        let router = M.services().keyRouter!
        let letter = try K.key("h", keyCode: 4, [])
        for focus in [M.focused(.agent, tab: "local-agent:1"), M.focused(.page, tab: "local-page:keybindings:1")] {
            #expect(router.decide(letter, focus: focus, keyWindow: .content, facts: Self.loading) == .typeAhead)
            #expect(router.decide(letter, focus: focus, keyWindow: .content, facts: KeyRouter.Facts()) == .deliver, "a loaded page types itself")
            let palette = try K.key("p", keyCode: 35, [.command, .shift])
            #expect(router.decide(palette, focus: focus, keyWindow: .content, facts: Self.loading) == .run(
                KeyRouter.Candidate(id: "commandPalette", tier: .system, source: .registry(argument: nil))))
            // Navigation keys are not typing.
            #expect(router.decide(try K.key("\r", keyCode: 36, []), focus: focus, keyWindow: .content, facts: Self.loading) == .deliver)
        }
        // A terminal or a web page never queues.
        for focus in [M.terminal, M.page] {
            #expect(router.decide(letter, focus: focus, keyWindow: .content, facts: Self.loading) == .deliver)
        }
    }

    @Test func theQueueKeepsOrderAndBounds() {
        let start = ContinuousClock.now
        var queue = TypeAheadQueue()
        queue.append("he", surface: "p1:t1", now: start)
        queue.append("llo", surface: "p1:t1", now: start + .milliseconds(300))
        #expect(queue.pending(for: "p1:t1"))
        #expect(!queue.pending(for: "p1:t2"))
        #expect(queue.take(surface: "p1:t1", now: start + .seconds(1)) == "hello")
        #expect(queue.take(surface: "p1:t1", now: start + .seconds(1)) == nil, "taken once")

        queue.append(String(repeating: "a", count: 300), surface: "p1:t1", now: start)
        #expect(queue.take(surface: "p1:t1", now: start)?.count == TypeAheadQueue.maxCharacters)

        queue.append("hi", surface: "p1:t1", now: start)
        queue.deleteBackward(surface: "p1:t1")
        #expect(queue.take(surface: "p1:t1", now: start) == "h", "Delete edits the queue")
    }

    @Test func theQueueDropsOnTimeoutAnotherSurfaceOrADrop() {
        let start = ContinuousClock.now
        var queue = TypeAheadQueue()
        queue.append("late", surface: "p1:t1", now: start)
        #expect(queue.take(surface: "p1:t1", now: start + .milliseconds(2001)) == nil, "older than 2 s")
        queue.append("old", surface: "p1:t1", now: start)
        queue.append("new", surface: "p2:t9", now: start)
        #expect(queue.take(surface: "p1:t1", now: start) == nil, "another surface replaces it")
        #expect(queue.take(surface: "p2:t9", now: start) == "new")
        queue.append("x", surface: "p1:t1", now: start)
        queue.drop()
        #expect(!queue.pending(for: "p1:t1"))
    }
}
