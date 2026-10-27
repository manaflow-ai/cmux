import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Dispatch
import Testing

/// The system lane's reserve and host-resolution cap (plans/cmux-next/chrome-parity/p02-threads.md, task 059):
/// one of its six slots runs only user-blocking items of no capped class, counted against every busy slot, and at
/// most four host resolutions run at once, so no mix of hung resolvers and hung lower work delays the keychain read
/// or AX call a person waits for. Chrome's `PrioritizedDispatcher` reserved slots (net/base/prioritized_dispatcher.h);
/// the cap of four is cmux's.
///
/// Each test fails by its time limit when the guarantee breaks: the user-blocking item would wait behind items
/// that only the test's final release lets end.
@Suite(.timeLimit(.minutes(1))) struct SystemLaneReserveTests {
    /// Lane bodies (synchronous) report that they started or were queued; the async test awaits the reports.
    struct Signal: Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }

        func signal() { continuation.yield() }

        func wait(_ count: Int) async {
            var left = count
            guard left > 0 else { return }
            for await _ in stream {
                left -= 1
                if left == 0 { return }
            }
        }
    }

    @Test func theSystemLaneReservesOneSlotAndCapsLookupsAtFour() {
        #expect(BackgroundWork.systemWidth == 6)
        #expect(BackgroundWork.systemReserved == 1)
        #expect(BackgroundWork.hostResolutionCap == 4)
    }

    @Test func sixHungLookupsDoNotDelayAUserBlockingSystemItem() async throws {
        let queued = Signal(), started = Signal()
        let work = BackgroundWork(label: "test.dns-cap", onQueued: { lane, _ in if lane == .system { queued.signal() } })
        let release = DispatchSemaphore(value: 0)
        let lookups = (0..<6).map { _ in
            Task { try await work.resolveHost(.userBlocking) { started.signal(); release.wait() } }
        }
        // Four lookups hang on their slots; the other two wait for the cap, not for a slot.
        await started.wait(BackgroundWork.hostResolutionCap)
        await queued.wait(6 - BackgroundWork.hostResolutionCap)
        // A keychain-class item starts on a free slot and returns while every lookup still hangs.
        let answer = try await work.run(.userBlocking, mayBlock: .system) { () throws -> Int in 42 }
        #expect(answer == 42)
        for _ in 0..<6 { release.signal() }
        for lookup in lookups { try await lookup.value }
    }

    @Test func hungLowerWorkNeverTakesTheReservedSlot() async throws {
        let queued = Signal(), started = Signal()
        let work = BackgroundWork(label: "test.reserve", onQueued: { lane, _ in if lane == .system { queued.signal() } })
        let release = DispatchSemaphore(value: 0)
        let width = BackgroundWork.systemWidth
        // User-visible work: best effort stops at its own cap of two (task 115) before it reaches the reserve.
        for _ in 0..<width {
            work.post(.userVisible, mayBlock: .system) {
                started.signal()
                release.wait()
            }
        }
        // User-visible work fills every slot but the reserved one; the last item waits.
        await started.wait(width - BackgroundWork.systemReserved)
        await queued.wait(1)
        let answer = try await work.run(.userBlocking, mayBlock: .system) { () throws -> Int in 7 }
        #expect(answer == 7)
        for _ in 0..<width { release.signal() }
        await started.wait(1)
    }

    /// Every busy slot counts against the reserve, not only the ones below user-blocking: four hung user-blocking
    /// lookups and one hung best-effort item fill the five open slots, so the second best-effort item waits and
    /// the reserved slot stays free.
    @Test func hungLookupsAndHungLowerWorkTogetherLeaveTheReservedSlot() async throws {
        let queued = Signal(), started = Signal()
        let work = BackgroundWork(label: "test.reserve-mix", onQueued: { lane, _ in if lane == .system { queued.signal() } })
        let release = DispatchSemaphore(value: 0)
        let cap = BackgroundWork.hostResolutionCap
        let lookups = (0..<cap).map { _ in
            Task { try await work.resolveHost(.userBlocking) { started.signal(); release.wait() } }
        }
        await started.wait(cap)
        for _ in 0..<2 {
            work.post(.bestEffort, mayBlock: .system) {
                started.signal()
                release.wait()
            }
        }
        await started.wait(1)
        await queued.wait(1)
        let answer = try await work.run(.userBlocking, mayBlock: .system) { () throws -> Int in 11 }
        #expect(answer == 11)
        for _ in 0..<(cap + 2) { release.signal() }
        for lookup in lookups { try await lookup.value }
        await started.wait(1)
    }

    /// A capped item never takes the reserved slot, even at user-blocking: with the five open slots held by hung
    /// lower work, a user-blocking lookup waits and a user-blocking keychain-class item still starts.
    @Test func aUserBlockingLookupNeverTakesTheReservedSlot() async throws {
        let queued = Signal(), started = Signal()
        let work = BackgroundWork(label: "test.reserve-capped", onQueued: { lane, _ in if lane == .system { queued.signal() } })
        let release = DispatchSemaphore(value: 0)
        let open = BackgroundWork.systemWidth - BackgroundWork.systemReserved
        for _ in 0..<open {
            work.post(.userVisible, mayBlock: .system) {
                started.signal()
                release.wait()
            }
        }
        await started.wait(open)
        let lookup = Task { try await work.resolveHost(.userBlocking) { started.signal(); release.wait() } }
        await queued.wait(1)
        let answer = try await work.run(.userBlocking, mayBlock: .system) { () throws -> Int in 13 }
        #expect(answer == 13)
        for _ in 0...open { release.signal() }
        try await lookup.value
    }

    @Test func aFinishedLookupStartsTheNextOneTheCapHeld() async throws {
        let queued = Signal(), started = Signal()
        let work = BackgroundWork(label: "test.dns-next", onQueued: { lane, _ in if lane == .system { queued.signal() } })
        let release = DispatchSemaphore(value: 0)
        let cap = BackgroundWork.hostResolutionCap
        let lookups = (0...cap).map { _ in
            Task { try await work.resolveHost(.userVisible) { started.signal(); release.wait() } }
        }
        await started.wait(cap)
        // A free slot is left (width 6, one reserved, four lookups): the fifth lookup waits for the cap alone.
        await queued.wait(1)
        release.signal()
        await started.wait(1)
        for _ in 0..<cap { release.signal() }
        for lookup in lookups { try await lookup.value }
    }

    @Test func theRunnerSeamResolvesOnTheSystemLane() async throws {
        let runner: any MayBlockRunner = BackgroundWork(label: "test.dns-runner")
        let queue = try await runner.runHostResolution(.userVisible) { String(cString: __dispatch_queue_get_label(nil)) }
        #expect(queue.hasPrefix("test.dns-runner.system."), "ran on \(queue)")
    }
}
