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
}
