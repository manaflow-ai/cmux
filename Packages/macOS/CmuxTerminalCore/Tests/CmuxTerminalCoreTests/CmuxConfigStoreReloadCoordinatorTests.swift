import Testing
@testable import CmuxTerminalCore

@MainActor
private final class FakeConfigStore: CmuxConfigStoreReloading {
    private(set) var loadAllCount = 0
    func loadAll() { loadAllCount += 1 }
}

@MainActor
private final class FakeEnvironment: CmuxConfigStoreReloadEnvironment {
    var stores: [FakeConfigStore]
    private(set) var titleRefreshCount = 0

    init(stores: [FakeConfigStore]) { self.stores = stores }

    var reloadableConfigStores: [any CmuxConfigStoreReloading] { stores }
    func refreshWindowTitlesAfterConfigReload() { titleRefreshCount += 1 }
}

@MainActor
@Suite struct CmuxConfigStoreReloadCoordinatorTests {
    @Test func reloadsEachDistinctStoreOnceAndRefreshesTitles() {
        let storeA = FakeConfigStore()
        let storeB = FakeConfigStore()
        // storeA appears twice to simulate windows sharing a store.
        let env = FakeEnvironment(stores: [storeA, storeB, storeA])

        var reportedSource: String?
        var reportedCount: Int?
        let coordinator = CmuxConfigStoreReloadCoordinator(environment: env) { source, count in
            reportedSource = source
            reportedCount = count
        }

        coordinator.reload(source: "test.source")

        #expect(storeA.loadAllCount == 1)
        #expect(storeB.loadAllCount == 1)
        #expect(env.titleRefreshCount == 1)
        #expect(reportedSource == "test.source")
        #expect(reportedCount == 2)
    }

    @Test func reloadWithNoStoresStillRefreshesTitles() {
        let env = FakeEnvironment(stores: [])
        var reportedCount: Int?
        let coordinator = CmuxConfigStoreReloadCoordinator(environment: env) { _, count in
            reportedCount = count
        }

        coordinator.reload(source: "empty")

        #expect(env.titleRefreshCount == 1)
        #expect(reportedCount == 0)
    }

    @Test func reloadAfterEnvironmentDeallocatedReportsZero() {
        var env: FakeEnvironment? = FakeEnvironment(stores: [FakeConfigStore()])
        var reportedCount: Int?
        let coordinator = CmuxConfigStoreReloadCoordinator(environment: env!) { _, count in
            reportedCount = count
        }
        env = nil

        coordinator.reload(source: "after-dealloc")

        #expect(reportedCount == 0)
    }
}
