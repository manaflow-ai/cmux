@testable import CmuxNextActions
import CmuxNextCompat
import Testing

/// The launch's catalog build (p08-startup 092): `action_catalog_main_wait_ms` is 0 when the launch
/// warm-up thread built the catalog before the registry's read on the main thread, and is that read's
/// time only when the main thread waited for a build still running on another thread.
@Suite struct ActionCatalogLaunchTests {
    /// A clock that moves only when a test's read says so.
    private nonisolated final class FakeClock: Sendable {
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
        catalog.buildBegan()
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
        catalog.buildBegan()
        _ = catalog.descriptors()
        #expect(catalog.mainAccess == ActionCatalogMainAccess(outcome: .ready, microseconds: 3_000))
    }

    /// Sub-millisecond reads keep microsecond resolution.
    @Test func theReadIsRecordedInMicroseconds() {
        let catalog = launch(FakeClock(), readNanoseconds: 1_250_000)
        catalog.buildBegan()
        _ = catalog.descriptors()
        #expect(catalog.mainAccess?.milliseconds == 1.25)
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
