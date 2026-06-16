import Foundation
import Testing
@testable import CmuxBrowser

@MainActor
private final class FakeHistoryStore: BrowserProfileHistoryStore {
    var clearedWithoutLoading = false
    var canceled = false
    var flushed = false
    func clearHistoryWithoutLoadingPersistedFile() { clearedWithoutLoading = true }
    func cancelPendingSaves() { canceled = true }
    func flushPendingSaves() { flushed = true }
}

@MainActor
private final class FakeHistoryProvider: BrowserProfileHistoryProviding {
    let shared = FakeHistoryStore()
    private(set) var made: [FakeHistoryStore] = []
    var madeFileURLs: [URL?] = []
    var sharedFlushed = false
    var defaultURL: URL? = URL(fileURLWithPath: "/tmp/cmux-test-default/browser_history.json")

    var sharedHistoryStore: any BrowserProfileHistoryStore { shared }

    func makeHistoryStore(fileURL: URL?) -> any BrowserProfileHistoryStore {
        madeFileURLs.append(fileURL)
        let store = FakeHistoryStore()
        made.append(store)
        return store
    }

    func defaultHistoryFileURLForCurrentBundle() -> URL? { defaultURL }

    func normalizedBrowserHistoryNamespace(forBundleIdentifier bundleIdentifier: String) -> String {
        "ns-\(bundleIdentifier)"
    }

    func flushSharedHistoryPendingSaves() { sharedFlushed = true }
}

@MainActor
private final class FakeDataStore: NSObject {}

@MainActor
private final class FakeWebsiteDataStoreProvider: BrowserProfileWebsiteDataStoreProviding {
    let defaultStore = FakeDataStore()
    private(set) var madeCount = 0
    private(set) var removedFromStores: [ObjectIdentifier] = []
    var types = ["WKCookies", "WKLocalStorage"]

    var defaultWebsiteDataStore: AnyObject { defaultStore }

    func makeWebsiteDataStore(forProfileID profileID: UUID) -> AnyObject {
        madeCount += 1
        return FakeDataStore()
    }

    var allWebsiteDataTypes: [String] { types }

    func removeAllData(ofTypes dataTypes: [String], from store: AnyObject) async {
        removedFromStores.append(ObjectIdentifier(store))
    }
}

private actor FakeFileRemover: BrowserProfileFileRemoving {
    private(set) var removed: [URL] = []
    func removeItemIfExists(at url: URL) async { removed.append(url) }
    func removedURLs() -> [URL] { removed }
}

@MainActor
private func makeRepository(
    suiteName: String = "cmux.browserprofiles.test.\(UUID().uuidString)",
    history: FakeHistoryProvider = FakeHistoryProvider(),
    data: FakeWebsiteDataStoreProvider = FakeWebsiteDataStoreProvider(),
    files: FakeFileRemover = FakeFileRemover(),
    bundleIdentifier: String = "ai.manaflow.cmux.test"
) -> (BrowserProfileRepository, UserDefaults) {
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let repo = BrowserProfileRepository(
        defaults: defaults,
        historyProvider: history,
        websiteDataStoreProvider: data,
        fileRemover: files,
        bundleIdentifier: bundleIdentifier,
        defaultProfileDisplayName: "Default"
    )
    return (repo, defaults)
}

@Suite @MainActor
struct BrowserProfileRepositoryTests {
    @Test func freshLoadSeedsBuiltInDefault() {
        let (repo, defaults) = makeRepository()
        #expect(repo.profiles.count == 1)
        #expect(repo.profiles.first?.isBuiltInDefault == true)
        #expect(repo.profiles.first?.id == BrowserProfileRepository.builtInDefaultProfileID)
        #expect(repo.lastUsedProfileID == BrowserProfileRepository.builtInDefaultProfileID)
        // Persisted on first load.
        #expect(defaults.data(forKey: BrowserProfileRepository.profilesDefaultsKey) != nil)
        #expect(defaults.string(forKey: BrowserProfileRepository.lastUsedProfileDefaultsKey)
                == BrowserProfileRepository.builtInDefaultProfileID.uuidString)
    }

    @Test func createTrimsSortsPersistsAndMarksUsed() {
        let (repo, defaults) = makeRepository()
        let created = repo.createProfile(named: "  Work  ")
        #expect(created?.displayName == "Work")
        #expect(repo.lastUsedProfileID == created?.id)
        // Default sorts before the new profile.
        #expect(repo.profiles.first?.isBuiltInDefault == true)
        #expect(repo.profiles.last?.displayName == "Work")
        // Persisted.
        let raw = defaults.data(forKey: BrowserProfileRepository.profilesDefaultsKey)!
        let decoded = try! JSONDecoder().decode([BrowserProfileDefinition].self, from: raw)
        #expect(decoded.contains { $0.displayName == "Work" })
    }

    @Test func createRejectsEmptyName() {
        let (repo, _) = makeRepository()
        #expect(repo.createProfile(named: "   ") == nil)
        #expect(repo.profiles.count == 1)
    }

    @Test func alphabeticalSortAfterDefault() {
        let (repo, _) = makeRepository()
        _ = repo.createProfile(named: "Zeta")
        _ = repo.createProfile(named: "alpha")
        #expect(repo.profiles.map(\.displayName) == ["Default", "alpha", "Zeta"])
    }

    @Test func renameNonDefaultAndRejectDefault() {
        let (repo, _) = makeRepository()
        let p = repo.createProfile(named: "Old")!
        #expect(repo.renameProfile(id: p.id, to: " New ") == true)
        #expect(repo.profileDefinition(id: p.id)?.displayName == "New")
        #expect(repo.renameProfile(id: p.id, to: "  ") == false)
        #expect(repo.renameProfile(id: BrowserProfileRepository.builtInDefaultProfileID, to: "X") == false)
    }

    @Test func canRenameRules() {
        let (repo, _) = makeRepository()
        let p = repo.createProfile(named: "X")!
        #expect(repo.canRenameProfile(id: p.id) == true)
        #expect(repo.canRenameProfile(id: BrowserProfileRepository.builtInDefaultProfileID) == false)
        #expect(repo.canRenameProfile(id: UUID()) == false)
    }

    @Test func deleteResetsLastUsedAndCancelsHistory() {
        let history = FakeHistoryProvider()
        let (repo, _) = makeRepository(history: history)
        let p = repo.createProfile(named: "Temp")!
        // Materialize the history store so delete cancels it.
        _ = repo.historyStore(for: p.id)
        #expect(repo.lastUsedProfileID == p.id)
        let removed = repo.deleteProfile(id: p.id)
        #expect(removed?.id == p.id)
        #expect(repo.lastUsedProfileID == BrowserProfileRepository.builtInDefaultProfileID)
        #expect(history.made.first?.canceled == true)
        #expect(repo.profileDefinition(id: p.id) == nil)
    }

    @Test func deleteRejectsDefaultAndUnknown() {
        let (repo, _) = makeRepository()
        #expect(repo.deleteProfile(id: BrowserProfileRepository.builtInDefaultProfileID) == nil)
        #expect(repo.deleteProfile(id: UUID()) == nil)
    }

    @Test func websiteDataStoreCachesAndDefaultMapsToDefault() {
        let data = FakeWebsiteDataStoreProvider()
        let (repo, _) = makeRepository(data: data)
        let p = repo.createProfile(named: "P")!
        let first = repo.websiteDataStore(for: p.id)
        let second = repo.websiteDataStore(for: p.id)
        #expect(ObjectIdentifier(first) == ObjectIdentifier(second))
        #expect(data.madeCount == 1)
        let def = repo.websiteDataStore(for: BrowserProfileRepository.builtInDefaultProfileID)
        #expect(ObjectIdentifier(def) == ObjectIdentifier(data.defaultStore))
    }

    @Test func historyStoreCachesAndDefaultMapsToShared() {
        let history = FakeHistoryProvider()
        let (repo, _) = makeRepository(history: history)
        let p = repo.createProfile(named: "P")!
        let a = repo.historyStore(for: p.id)
        let b = repo.historyStore(for: p.id)
        #expect(ObjectIdentifier(a) == ObjectIdentifier(b))
        #expect(history.made.count == 1)
        let def = repo.historyStore(for: BrowserProfileRepository.builtInDefaultProfileID)
        #expect(ObjectIdentifier(def) == ObjectIdentifier(history.shared))
    }

    @Test func historyFileURLDefaultAndPerProfileShape() {
        let history = FakeHistoryProvider()
        let (repo, _) = makeRepository(history: history, bundleIdentifier: "ai.manaflow.cmux.test")
        #expect(repo.historyFileURL(for: BrowserProfileRepository.builtInDefaultProfileID) == history.defaultURL)
        let p = repo.createProfile(named: "P")!
        let url = repo.historyFileURL(for: p.id)!
        #expect(url.lastPathComponent == "browser_history.json")
        #expect(url.path.contains("ns-ai.manaflow.cmux.test"))
        #expect(url.path.contains("browser_profiles"))
        #expect(url.path.contains(p.id.uuidString.lowercased()))
    }

    @Test func clearProfileDataWipesAndReports() async {
        let history = FakeHistoryProvider()
        let data = FakeWebsiteDataStoreProvider()
        data.types = ["WKZeta", "WKAlpha"]
        let (repo, _) = makeRepository(history: history, data: data)
        let p = repo.createProfile(named: "P")!
        let outcome = await repo.clearProfileData(id: p.id)
        #expect(outcome?.profile.id == p.id)
        #expect(outcome?.clearedHistory == true)
        #expect(outcome?.clearedWebsiteDataTypes == ["WKAlpha", "WKZeta"]) // sorted
        #expect(history.made.first?.clearedWithoutLoading == true)
        #expect(data.removedFromStores.count == 1)
    }

    @Test func clearProfileDataUnknownReturnsNil() async {
        let (repo, _) = makeRepository()
        let outcome = await repo.clearProfileData(id: UUID())
        #expect(outcome == nil)
    }

    @Test func noteUsedIgnoresUnknownAndPersists() {
        let (repo, defaults) = makeRepository()
        repo.noteUsed(UUID())
        #expect(repo.lastUsedProfileID == BrowserProfileRepository.builtInDefaultProfileID)
        let p = repo.createProfile(named: "P")!
        repo.noteUsed(p.id)
        #expect(repo.lastUsedProfileID == p.id)
        #expect(defaults.string(forKey: BrowserProfileRepository.lastUsedProfileDefaultsKey) == p.id.uuidString)
    }

    @Test func effectiveLastUsedFallsBackWhenMissing() {
        let (_, defaults) = makeRepository()
        // Force lastUsed to a stale id via persistence, then reload.
        let stale = UUID()
        defaults.set(stale.uuidString, forKey: BrowserProfileRepository.lastUsedProfileDefaultsKey)
        let reloaded = BrowserProfileRepository(
            defaults: defaults,
            historyProvider: FakeHistoryProvider(),
            websiteDataStoreProvider: FakeWebsiteDataStoreProvider(),
            fileRemover: FakeFileRemover(),
            bundleIdentifier: "x",
            defaultProfileDisplayName: "Default"
        )
        #expect(reloaded.lastUsedProfileID == BrowserProfileRepository.builtInDefaultProfileID)
        #expect(reloaded.effectiveLastUsedProfileID == BrowserProfileRepository.builtInDefaultProfileID)
    }

    @Test func loadDedupesPersistedBuiltInDefault() {
        let suite = "cmux.browserprofiles.test.dedup.\(UUID().uuidString)"
        let (repo, defaults) = makeRepository(suiteName: suite)
        _ = repo.createProfile(named: "Keep")
        // Inject a duplicate built-in default into persisted data.
        let dupe = BrowserProfileDefinition(
            id: BrowserProfileRepository.builtInDefaultProfileID,
            displayName: "Bogus",
            createdAt: Date(),
            isBuiltInDefault: true
        )
        var stored = repo.profiles
        stored.append(dupe)
        defaults.set(try! JSONEncoder().encode(stored), forKey: BrowserProfileRepository.profilesDefaultsKey)
        let reloaded = BrowserProfileRepository(
            defaults: defaults,
            historyProvider: FakeHistoryProvider(),
            websiteDataStoreProvider: FakeWebsiteDataStoreProvider(),
            fileRemover: FakeFileRemover(),
            bundleIdentifier: "x",
            defaultProfileDisplayName: "Default"
        )
        let defaults0 = reloaded.profiles.filter { $0.isBuiltInDefault }
        #expect(defaults0.count == 1)
        #expect(defaults0.first?.displayName == "Default") // canonical, not "Bogus"
    }

    @Test func flushPendingSavesFlushesSharedAndCached() {
        let history = FakeHistoryProvider()
        let (repo, _) = makeRepository(history: history)
        let p = repo.createProfile(named: "P")!
        _ = repo.historyStore(for: p.id)
        repo.flushPendingSaves()
        #expect(history.sharedFlushed == true)
        #expect(history.made.first?.flushed == true)
    }

    @Test func slugRules() {
        let def = BrowserProfileDefinition(id: UUID(), displayName: "x", createdAt: Date(), isBuiltInDefault: true)
        #expect(def.slug == "default")
        let named = BrowserProfileDefinition(id: UUID(), displayName: "  My Work! ", createdAt: Date(), isBuiltInDefault: false)
        #expect(named.slug == "my-work")
        let id = UUID()
        let empty = BrowserProfileDefinition(id: id, displayName: "!!!", createdAt: Date(), isBuiltInDefault: false)
        #expect(empty.slug == id.uuidString.lowercased())
    }
}
