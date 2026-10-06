import Testing

@testable import CmuxBrowser

@MainActor
@Suite("Browser REPL pointer owner")
struct BrowserReplPointerOwnerTests {
    @Test func theOwnerAndFreePointerDoNotWait() async throws {
        let pointer = BrowserReplPointerOwner(timeout: .seconds(30))
        try await pointer.waitForPointer(sessionID: "a")
        pointer.pressed(sessionID: "a")
        try await pointer.waitForPointer(sessionID: "a")
        #expect(pointer.owner == "a")
    }

    @Test func anotherSessionFailsNamingTheHolderAfterTheTimeout() async throws {
        let pointer = BrowserReplPointerOwner(timeout: .milliseconds(50))
        pointer.pressed(sessionID: "holder")
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: BrowserReplPointerOwner.Held(owner: "holder", timeout: .milliseconds(50))) {
            try await pointer.waitForPointer(sessionID: "other", clock: clock)
        }
        #expect(clock.now - started < .seconds(5))
        #expect(pointer.owner == "holder")
    }

    @Test func aReleaseWakesTheWaitingSession() async throws {
        let pointer = BrowserReplPointerOwner(timeout: .seconds(30))
        pointer.pressed(sessionID: "holder")
        let waiter = Task { @MainActor in
            try await pointer.waitForPointer(sessionID: "other")
            return pointer.owner
        }
        await Task.yield()
        pointer.released(sessionID: "other")
        #expect(pointer.owner == "holder", "only the owner releases")
        pointer.released(sessionID: "holder")
        #expect(try await waiter.value == nil)
    }

    @Test func cancellingTheWaitEndsIt() async throws {
        let pointer = BrowserReplPointerOwner(timeout: .seconds(30))
        pointer.pressed(sessionID: "holder")
        let waiter = Task { @MainActor in
            try await pointer.waitForPointer(sessionID: "other")
        }
        await Task.yield()
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
    }

    // A whole drag holds the pointer: another session's mouse input waits
    // until the drag ends, so trusted drag events never interleave.
    @Test func aGestureHoldsThePointerUntilItEnds() async throws {
        let pointer = BrowserReplPointerOwner(timeout: .seconds(30))
        let gate = BrowserReplLatch()
        let clock = ContinuousClock()
        let drag = Task { @MainActor in
            try await pointer.performGesture(sessionID: "dragger") {
                _ = await gate.wait(until: clock.now.advanced(by: .seconds(30)), clock: clock)
                return pointer.owner
            }
        }
        while pointer.owner == nil { await Task.yield() }
        #expect(pointer.owner == "dragger")
        var otherReached = false
        let other = Task { @MainActor in
            try await pointer.waitForPointer(sessionID: "other")
            otherReached = true
            return pointer.owner
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!otherReached, "another session's input waits while the drag runs")
        gate.signal()
        #expect(try await drag.value == "dragger")
        #expect(try await other.value == nil, "the other session ran after the drag released")
    }

    @Test func aGestureWaitsForAnotherSessionsPressAndReleasesWhenItFails() async throws {
        let pointer = BrowserReplPointerOwner(timeout: .milliseconds(50))
        pointer.pressed(sessionID: "holder")
        await #expect(throws: BrowserReplPointerOwner.Held(owner: "holder", timeout: .milliseconds(50))) {
            try await pointer.performGesture(sessionID: "dragger") { Issue.record("the gesture ran while another session held the mouse") }
        }
        pointer.released(sessionID: "holder")
        struct Failed: Error {}
        await #expect(throws: Failed.self) {
            try await pointer.performGesture(sessionID: "dragger") { throw Failed() }
        }
        #expect(pointer.owner == nil, "a failed gesture releases the pointer")
    }

    /// A gesture (a drag) arms per-tab state (the drag capture, the held
    /// button) that the next session's mouse input would act on. It is
    /// cleared on every outcome, also when the gesture throws partway, and
    /// before another session's waiting input gets the pointer.
    @Test func aGesturesStateEndsOnEveryOutcomeBeforeAnotherSessionGetsThePointer() async throws {
        struct Failed: Error {}
        let pointer = BrowserReplPointerOwner(timeout: .seconds(30))
        var armed: String?
        var seenByOther: [String?] = []
        await #expect(throws: Failed.self) {
            try await pointer.performGesture(sessionID: "dragger", ending: { armed = nil }) {
                armed = "dragger"
                let other = Task { @MainActor in
                    try await pointer.waitForPointer(sessionID: "other")
                    seenByOther.append(armed)
                }
                await Task.yield()
                _ = other
                throw Failed()
            }
        }
        try await pointer.waitForPointer(sessionID: "other")
        #expect(armed == nil, "a failed gesture left its state armed")
        #expect(!seenByOther.contains { $0 != nil }, "another session saw the failed gesture's state")

        var endings = 0
        try await pointer.performGesture(sessionID: "dragger", ending: { endings += 1 }) {}
        #expect(endings == 1)
    }
}
