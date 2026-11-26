import Darwin
import Foundation
import Synchronization
import Testing
@testable import CmuxMobileModel

/// Hang recovery on the iPhone: known main-thread waits are cancelled by the watchdog thread
/// once past their bound, and a hard hang leaves a restore marker the next launch reads once.
@Suite(.serialized, .timeLimit(.minutes(1))) struct HangRecoveryTests {
    /// A registered wait past its bound is cancelled by the watchdog's thread, off the
    /// watched thread, while a wait that finished in time is never cancelled.
    @Test func aRegisteredWaitPastItsBoundIsCancelledByTheWatchdog() async throws {
        let waits = MainThreadWaitRegistry()
        let watchdog = MainThreadHangWatchdog(configuration: .init(threshold: .milliseconds(50), hangThreshold: .seconds(30)), waits: waits)
        let cancelled = HangTestFlag()
        let cancelledOnWatchdog = HangTestFlag()
        let finishedCancelled = HangTestFlag()
        let watched = Atomic<UInt32>(0)
        await runOwnLoop(watchdog, seconds: 1) {
            watched.store(pthread_mach_thread_np(pthread_self()), ordering: .releasing)
            let early = waits.register("finishes", bound: .milliseconds(100)) { finishedCancelled.set() }
            early.finish()
            _ = waits.register("stuck", bound: .milliseconds(150)) {
                cancelled.set()
                if watched.load(ordering: .acquiring) != pthread_mach_thread_np(pthread_self()) { cancelledOnWatchdog.set() }
            }
        }
        #expect(cancelled.isSet, "the stuck wait was not cancelled")
        #expect(cancelledOnWatchdog.isSet, "the cancel ran on the watched thread")
        #expect(!finishedCancelled.isSet, "a finished wait was cancelled")
        #expect(waits.count == 0)
    }

    /// The watchdog's cancel ends a `BoundedWait` whose own timer never fires (a clock that
    /// never moves stands for a starved executor): the waiter gets "gave up", not a freeze.
    @Test func aBoundedWaitWhoseTimerIsStarvedIsEndedByTheWatchdog() async throws {
        let waits = MainThreadWaitRegistry()
        let watchdog = MainThreadHangWatchdog(configuration: .init(threshold: .milliseconds(50), hangThreshold: .seconds(30)), waits: waits)
        watchdog.running.store(true, ordering: .releasing)
        waits.setWaker { [alarm = watchdog.alarm] in alarm.wake() }
        let thread = Thread { watchdog.watch(sampler: nil) }
        thread.start()
        defer { watchdog.stop() }
        let started = ContinuousClock.now
        let finished = await BoundedWait(.milliseconds(200)).run(on: NeverClock(), registry: waits, label: "test") {
            try? await Task.sleep(for: .seconds(30))
        }
        #expect(!finished)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// Past the hard bound the watchdog hands the hang to `onHardHang` once, while it lasts.
    @Test func aHardHangReachesOnHardHangOnce() async throws {
        let watchdog = MainThreadHangWatchdog(configuration: .init(threshold: .milliseconds(50), hangThreshold: .milliseconds(200),
                                                                   hardHangThreshold: .milliseconds(400)))
        let hard = HangsSeen()
        watchdog.onHardHang = { hang in hard.hangs.withLock { $0.append(hang) } }
        await runOwnLoop(watchdog, seconds: 1.5) { spinForHangTest(.milliseconds(700)) }
        let hangs = hard.hangs.withLock { $0 }
        #expect(hangs.count == 1, "\(hangs)")
        #expect(hangs.first.map { $0.duration >= .milliseconds(400) && !$0.ended } == true)
    }

    /// A hard hang that ends (the main thread turns again) reaches `onHardHangEnded` once with
    /// its whole length, and the marker it wrote is cleared: a recovered hang is not reported as
    /// a prior hang on the next launch. A hang that never reached the hard bound does not.
    @Test func aHardHangThatEndsClearsItsRestoreMarker() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let watchdog = MainThreadHangWatchdog(configuration: .init(threshold: .milliseconds(50), hangThreshold: .milliseconds(200),
                                                                   hardHangThreshold: .milliseconds(400)))
        let wrote = HangTestFlag()
        let ended = HangsSeen()
        watchdog.onHardHang = { _ in
            HangRestoreMarker(hangStarted: Date(), durationMilliseconds: 400, location: nil).write(to: url)
            wrote.set()
        }
        watchdog.onHardHangEnded = { hang in
            ended.hangs.withLock { $0.append(hang) }
            HangRestoreMarker.clear(at: url)
        }
        await runOwnLoop(watchdog, seconds: 1.5) {
            spinForHangTest(.milliseconds(300))
            spinForHangTest(.milliseconds(700))
        }
        #expect(wrote.isSet, "no marker was written")
        let hangs = ended.hangs.withLock { $0 }
        #expect(hangs.count == 1, "\(hangs)")
        #expect(hangs.first.map { $0.ended && $0.duration >= .milliseconds(700) } == true, "\(hangs)")
        #expect(!FileManager.default.fileExists(atPath: url.path), "a recovered hang left its marker")
        #expect(HangRestoreMarker.handlePriorHang(at: url, lastOpen: .inMemory()) == nil)
    }

    /// The marker is read once: it reports the prior hang, hands its screen to the launch
    /// restore when none is saved, and is gone after.
    @Test func theRestoreMarkerIsReadOnceAndRestoresTheScreen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let location = LastOpenLocation(rootTab: LastOpenLocation.workspacesTab, workspaceID: "ws", macID: "mac", tabID: "tab")
        let marker = HangRestoreMarker(hangStarted: Date(timeIntervalSince1970: 1_800_000_000), durationMilliseconds: 8_000, location: location)
        marker.write(to: url)
        let memory = LastOpenMemory.inMemory()
        #expect(HangRestoreMarker.handlePriorHang(at: url, lastOpen: memory) == marker)
        #expect(memory.load() == location)
        #expect(HangRestoreMarker.handlePriorHang(at: url, lastOpen: memory) == nil, "reported twice")
    }
}

/// A clock whose sleeps never end (until cancelled): a timer that cannot fire.
struct NeverClock: Clock {
    var now: ContinuousClock.Instant { .now }
    var minimumResolution: Swift.Duration { .zero }
    func sleep(until deadline: ContinuousClock.Instant, tolerance: Swift.Duration?) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
}
