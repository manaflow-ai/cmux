@testable import CmuxNextActions
import CmuxNextCompat
import Dispatch
import Foundation
import Testing

/// The launch's catalog build (p08-startup 092): `action_catalog_main_wait_ms` is 0 when the launch
/// warm-up thread built the catalog before the registry's read on the main thread, and is that read's
/// time only when the main thread waited for a build still running on another thread.
@Suite struct ActionCatalogLaunchTests {
    /// A clock that moves only when a test's read says so.
    nonisolated final class FakeClock: Sendable {
        let nanoseconds = Atomic<UInt64>(1_000_000)
        func advance(nanoseconds delta: UInt64) { nanoseconds.add(delta, ordering: .relaxed) }
    }

    /// A build whose every read costs `readNanoseconds` on `clock`.
    private func launch(_ clock: FakeClock, readNanoseconds: UInt64 = 0) -> ActionCatalogLaunch {
        ActionCatalogLaunch(read: {
            clock.advance(nanoseconds: readNanoseconds)
            return []
        }, uptimeNanoseconds: { clock.nanoseconds.load(ordering: .relaxed) })
    }

    @Test func aFinishedBuildCostsTheMainThreadNoWait() {
        let catalog = launch(FakeClock())
        catalog.build()
        _ = catalog.descriptors()
        #expect(catalog.mainAccess == ActionCatalogMainAccess(outcome: .ready, microseconds: 0))
        #expect(catalog.mainAccess?.waitMilliseconds == 0)
    }

    @Test func aBuildStillRunningIsRecordedAsTheMainThreadsWait() {
        let catalog = launch(FakeClock(), readNanoseconds: 12_000_000)
        #expect(catalog.claimBuild())
        _ = catalog.descriptors()
        #expect(catalog.mainAccess == ActionCatalogMainAccess(outcome: .waited, microseconds: 12_000))
        #expect(catalog.mainAccess?.waitMilliseconds == 12)
        #expect(catalog.mainAccess?.waitMicroseconds == 12_000)
    }

    @Test func noBuildStartedMeansTheMainThreadBuildsItAndDoesNotWait() {
        let catalog = launch(FakeClock(), readNanoseconds: 60_000_000)
        _ = catalog.descriptors()
        #expect(catalog.mainAccess == ActionCatalogMainAccess(outcome: .builtOnMain, microseconds: 60_000))
        #expect(catalog.mainAccess?.waitMilliseconds == 0)
    }

    @Test func nothingIsRecordedBeforeTheRegistrysRead() {
        let catalog = launch(FakeClock())
        catalog.build()
        #expect(catalog.mainAccess == nil)
    }

    @Test func onlyTheFirstReadIsRecorded() {
        let catalog = launch(FakeClock(), readNanoseconds: 3_000_000)
        catalog.build()
        _ = catalog.descriptors()
        #expect(!catalog.claimBuild())
        _ = catalog.descriptors()
        #expect(catalog.mainAccess == ActionCatalogMainAccess(outcome: .ready, microseconds: 3_000))
    }

    /// Sub-millisecond reads keep microsecond resolution.
    @Test func theReadIsRecordedInMicroseconds() {
        let catalog = launch(FakeClock(), readNanoseconds: 1_250_000)
        #expect(catalog.claimBuild())
        _ = catalog.descriptors()
        #expect(catalog.mainAccess?.milliseconds == 1.25)
    }

    /// The warm-up thread's build is inside the catalog's `swift_once` when main reads: main's read blocks until
    /// that build ends, and the blocked time is the recorded wait.
    @Test func mainBlockedInAConcurrentBuildRecordsTheBlockedTimeAsItsWait() {
        let clock = FakeClock()
        let once = BlockingOnce(clock: clock, buildNanoseconds: 9_000_000)
        let catalog = ActionCatalogLaunch(read: { once.read() }, uptimeNanoseconds: { clock.nanoseconds.load(ordering: .relaxed) })
        let warmup = Thread { catalog.build() }
        warmup.name = "action-catalog-launch-test-warmup"
        warmup.qualityOfService = .userInitiated
        warmup.start()
        #expect(once.buildEntered.wait(timeout: .now() + 10) == .success)
        _ = catalog.descriptors()
        #expect(catalog.mainAccess == ActionCatalogMainAccess(outcome: .waited, microseconds: 9_000))
        #expect(catalog.mainAccess?.waitMicroseconds == 9_000)
        #expect(once.builds.load(ordering: .relaxed) == 1)
    }

    /// Main claims the build when nothing started it: a later warm-up build does not read the catalog again.
    @Test func aBuildAfterMainsClaimSkipsTheRead() {
        let reads = ReadCount()
        let catalog = ActionCatalogLaunch(read: { reads.read() }, uptimeNanoseconds: { 0 })
        _ = catalog.descriptors()
        #expect(!catalog.build())
        #expect(catalog.mainAccess?.outcome == .builtOnMain)
        #expect(reads.count.load(ordering: .relaxed) == 1)
    }

    /// Only one build claims the catalog.
    @Test func aSecondBuildSkipsTheRead() {
        let reads = ReadCount()
        let catalog = ActionCatalogLaunch(read: { reads.read() }, uptimeNanoseconds: { 0 })
        #expect(catalog.build())
        #expect(!catalog.build())
        #expect(reads.count.load(ordering: .relaxed) == 1)
    }

    /// The app's catalog: the registry built from the launch's build has every catalog action.
    @Test func theRegistryTakesTheBuiltCatalog() {
        let catalog = ActionCatalogLaunch()
        catalog.build()
        let registry = ActionRegistry.standard(launch: catalog, runTiming: NoActionRunTiming())
        #expect(catalog.mainAccess?.outcome == .ready)
        #expect(ActionCatalog.all.allSatisfy { registry.descriptor(for: $0.id) != nil })
    }
}

/// A catalog read that counts its calls.
private nonisolated final class ReadCount: Sendable {
    let count = Atomic<Int>(0)

    func read() -> [ActionDescriptor] {
        count.add(1, ordering: .relaxed)
        return []
    }
}

/// A `swift_once` stand-in: the first reader builds (it waits until a second reader arrives, then takes
/// `buildNanoseconds` on the clock), and every later reader blocks until that build ends.
private nonisolated final class BlockingOnce: Sendable {
    let buildEntered = DispatchSemaphore(value: 0)
    let builds = Atomic<Int>(0)
    private let waiterArrived = DispatchSemaphore(value: 0)
    private let buildDone = DispatchSemaphore(value: 0)
    private let started = Atomic<Bool>(false)
    private let clock: ActionCatalogLaunchTests.FakeClock
    private let buildNanoseconds: UInt64

    init(clock: ActionCatalogLaunchTests.FakeClock, buildNanoseconds: UInt64) {
        self.clock = clock
        self.buildNanoseconds = buildNanoseconds
    }

    func read() -> [ActionDescriptor] {
        if started.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged {
            builds.add(1, ordering: .relaxed)
            buildEntered.signal()
            _ = waiterArrived.wait(timeout: .now() + 10)
            clock.advance(nanoseconds: buildNanoseconds)
            buildDone.signal()
        } else {
            waiterArrived.signal()
            _ = buildDone.wait(timeout: .now() + 10)
            buildDone.signal()
        }
        return []
    }
}
