import CmuxNextCompat
@testable import CmuxNextRemoteViewSessions
import CmuxNextWakeups
import CmuxVNC
import Darwin
import Foundation
import Testing

/// A VNC tab's saved sign-in: memory answers at once with no Keychain call; otherwise one Keychain read runs on the
/// app's system lane and its answer reaches the main thread through the scheduler, unless a newer read, a stop or a
/// close came first (plans/cmux-next/chrome-parity/p02-threads.md, tasks 054-055).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteVNCSignInReadTests {
    nonisolated static let laneLabel = "test.vnc-sign-in"
    private static let account = "mac.example:5900"

    /// A Keychain in memory that records whether each read ran on the main thread or a system lane slot.
    nonisolated final class FakeKeychain: Sendable {
        private let state = Mutex<(saved: VNCCredentials?, reads: [Bool])>((nil, []))

        init(saved: VNCCredentials?) {
            state.withLock { $0.saved = saved }
        }

        /// One entry per read: true when it ran on a system lane slot, off the main thread.
        var reads: [Bool] { state.withLock { $0.reads } }

        func read() -> VNCCredentials? {
            let label = String(cString: __dispatch_queue_get_label(nil))
            let onLane = pthread_main_np() == 0 && label.hasPrefix(RemoteVNCSignInReadTests.laneLabel + ".system")
            return state.withLock { state in
                state.reads.append(onLane)
                return state.saved
            }
        }
    }

    /// What the reads gave: each answer in order, and the drops.
    final class Outcomes {
        var answers: [VNCCredentials?] = []
        var drops = 0
        var onMain = true

        func answered(_ saved: VNCCredentials?) {
            answers.append(saved)
            onMain = onMain && pthread_main_np() != 0
        }

        func dropped() {
            drops += 1
            onMain = onMain && pthread_main_np() != 0
        }
    }

    private let saved = VNCCredentials(username: "ada", password: "secret")

    private func reads(_ keychain: FakeKeychain, memory: RemoteVNCSignIns = RemoteVNCSignIns()) -> RemoteVNCSignInReads {
        RemoteVNCSignInReads(work: BackgroundWork(label: Self.laneLabel), mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                             memory: memory, account: Self.account, keychain: { keychain.read() })
    }

    private func read(_ reads: RemoteVNCSignInReads, into outcomes: Outcomes) {
        reads.read(dropped: { outcomes.dropped() }) { outcomes.answered($0) }
    }

    /// Runs main run loop passes (where a reply posted from a lane lands) until `done` or 5 s.
    private static func spinMainRunLoop(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    @Test func aSavedSignInIsReadOnTheSystemLaneOnceThenFromMemory() {
        let keychain = FakeKeychain(saved: saved)
        let signIns = reads(keychain)
        let outcomes = Outcomes()
        read(signIns, into: outcomes)
        #expect(outcomes.answers.isEmpty, "the read answered before the system lane")
        Self.spinMainRunLoop { !outcomes.answers.isEmpty }
        read(signIns, into: outcomes)

        #expect(outcomes.answers == [saved, saved])
        #expect(outcomes.onMain)
        #expect(keychain.reads == [true])
    }

    @Test func memoryThatKnowsTheAnswerReadsNoKeychain() {
        let keychain = FakeKeychain(saved: saved)
        let memory = RemoteVNCSignIns()
        memory.listed([])
        let outcomes = Outcomes()
        let signIns = reads(keychain, memory: memory)
        // Listed with no item: no Keychain read (the fallback, none here, still runs on the lane).
        read(signIns, into: outcomes)
        Self.spinMainRunLoop { !outcomes.answers.isEmpty }
        // A sign-in the host accepted is kept at once.
        signIns.saved(saved)
        read(signIns, into: outcomes)

        #expect(outcomes.answers == [nil, saved])
        #expect(keychain.reads.isEmpty)
    }

    @Test func aNewerReadDropsTheOlderAnswer() {
        let keychain = FakeKeychain(saved: saved)
        let signIns = reads(keychain)
        let outcomes = Outcomes()
        read(signIns, into: outcomes)
        read(signIns, into: outcomes)
        Self.spinMainRunLoop { outcomes.answers.count + outcomes.drops == 2 }

        #expect(outcomes.drops == 1)
        #expect(outcomes.answers == [saved])
        #expect(outcomes.onMain)
        #expect(keychain.reads.allSatisfy { $0 })
    }

    @Test func aStopDropsTheReadInFlight() {
        let keychain = FakeKeychain(saved: saved)
        let signIns = reads(keychain)
        let outcomes = Outcomes()
        read(signIns, into: outcomes)
        signIns.cancel()
        Self.spinMainRunLoop { outcomes.drops == 1 }

        #expect(outcomes.drops == 1)
        #expect(outcomes.answers.isEmpty)
        #expect(outcomes.onMain)
    }
}
