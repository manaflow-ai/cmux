import Foundation
import Observation
import Testing

@testable import CmuxMobileBrowser

/// The store owns at most one browser surface per workspace and survives Mac
/// re-syncs. These guard the open/reveal/close semantics the shell UI relies on.
@MainActor
@Suite struct BrowserSurfaceStoreTests {
    private func makeStore() -> BrowserSurfaceStore {
        var counter = 0
        return BrowserSurfaceStore(
            defaultURL: URL(string: "https://duckduckgo.com/"),
            makeSurfaceID: {
                counter += 1
                return BrowserSurfaceState.ID(rawValue: "surface-\(counter)")
            }
        )
    }

    @Test func noBrowserByDefault() {
        let store = makeStore()
        #expect(store.hasBrowser(for: "ws-1") == false)
        #expect(store.activeBrowser(for: "ws-1") == nil)
    }

    @Test func openBrowserCreatesSurfaceForWorkspace() {
        let store = makeStore()
        let surface = store.openBrowser(for: "ws-1")
        #expect(store.hasBrowser(for: "ws-1"))
        #expect(store.activeBrowser(for: "ws-1") === surface)
        #expect(store.browser(for: "ws-1") === surface)
        #expect(store.isBrowserSelected(for: "ws-1"))
        #expect(surface.id == .init(rawValue: "surface-1"))
        #expect(surface.consumeLoadRequest()?.absoluteString == "https://duckduckgo.com/")
    }

    @Test func openBrowserTwiceRevealsSameSurface() {
        let store = makeStore()
        let first = store.openBrowser(for: "ws-1")
        let second = store.openBrowser(for: "ws-1")
        // Same instance, so the current page is restored when switching away and
        // back. WebKit session snapshots are stored on that surface across
        // remounts.
        #expect(first === second)
    }

    @Test func aliasLookupWaitsForAuthoritativeUniqueReconciliation() {
        let store = makeStore()
        let browser = store.openBrowser(for: "legacy-workspace")
        let stableIdentity = BrowserWorkspaceIdentity(
            rawValue: "5:mac-a:workspace",
            aliases: ["legacy-workspace"]
        )

        #expect(store.browser(for: stableIdentity) == nil)
        #expect(store.browser(for: "legacy-workspace") === browser)

        store.reconcileWorkspaces([stableIdentity])

        #expect(store.openBrowser(for: stableIdentity) === browser)
        #expect(store.browser(for: stableIdentity) === browser)
        #expect(store.browser(for: "legacy-workspace") == nil)
    }

    @Test func partialMultiMacLookupCannotClaimAmbiguousRestoredAlias() {
        let store = makeStore()
        let restored = store.openBrowser(for: "shared")
        let firstIdentity = BrowserWorkspaceIdentity(
            rawValue: "5:mac-a:shared",
            aliases: ["shared"]
        )
        let secondIdentity = BrowserWorkspaceIdentity(
            rawValue: "5:mac-b:shared",
            aliases: ["shared"]
        )

        #expect(store.browser(for: firstIdentity) == nil)
        #expect(store.browser(for: secondIdentity) == nil)
        #expect(store.browser(for: "shared") === restored)

        store.reconcileWorkspaces([firstIdentity])

        #expect(store.browser(for: firstIdentity) === restored)
        #expect(store.browser(for: "shared") == nil)
    }

    @Test func browsersAreScopedPerWorkspace() {
        let store = makeStore()
        let a = store.openBrowser(for: "ws-1")
        let b = store.openBrowser(for: "ws-2")
        #expect(a !== b)
        #expect(store.activeBrowser(for: "ws-1") === a)
        #expect(store.activeBrowser(for: "ws-2") === b)
    }

    @Test func selectingTerminalRetainsBrowserIdentityAndSessionState() {
        let store = makeStore()
        let browser = store.openBrowser(for: "ws-1")
        browser.navigationDidFinish(
            url: URL(string: "https://example.com/docs")!,
            title: "Docs"
        )

        store.showNonBrowserSurface(for: "ws-1")

        #expect(store.activeBrowser(for: "ws-1") == nil)
        #expect(store.browser(for: "ws-1") === browser)
        #expect(store.hasBrowser(for: "ws-1"))

        let reopened = store.openBrowser(for: "ws-1")
        #expect(reopened === browser)
        #expect(reopened.id == .init(rawValue: "surface-1"))
        #expect(reopened.currentURL?.absoluteString == "https://example.com/docs")
        #expect(reopened.title == "Docs")
    }

    @Test func workspaceReorderingAndUnrelatedHostStateCannotRetargetBrowsers() {
        let store = makeStore()
        let first = store.openBrowser(for: "ws-1")
        let second = store.openBrowser(for: "ws-2")

        // Lookup order models workspace-list reorder and reconnect refreshes:
        // identity remains keyed only by the remote workspace ID.
        for workspaceID in ["ws-2", "ws-1", "ws-2", "ws-1"] {
            let expected = workspaceID == "ws-1" ? first : second
            #expect(store.browser(for: workspaceID) === expected)
        }
    }

    @Test func closeBrowserClearsOnlyThatWorkspace() {
        let store = makeStore()
        _ = store.openBrowser(for: "ws-1")
        _ = store.openBrowser(for: "ws-2")
        store.closeBrowser(for: "ws-1")
        #expect(store.hasBrowser(for: "ws-1") == false)
        #expect(store.hasBrowser(for: "ws-2"))
    }

    @Test func reconciliationPrunesBrowsersForDeletedWorkspaces() {
        let store = makeStore()
        _ = store.openBrowser(for: "ws-1")
        _ = store.openBrowser(for: "ws-2")

        store.reconcileWorkspaces(["ws-2"])

        #expect(store.hasBrowser(for: "ws-1") == false)
        #expect(store.hasBrowser(for: "ws-2"))
    }

    @Test func stableWorkspaceIdentityAdoptsBrowserFromRemoteAlias() {
        let store = makeStore()
        let browser = store.openBrowser(for: "remote-ws")
        let stableIdentity = BrowserWorkspaceIdentity(
            rawValue: "5:mac-a:remote-ws",
            aliases: ["remote-ws"]
        )

        store.reconcileWorkspaces([stableIdentity])

        #expect(store.browser(for: stableIdentity) === browser)
        #expect(store.browser(for: "remote-ws") == nil)
        #expect(store.activeBrowser(for: stableIdentity) === browser)
    }

    @Test func ambiguousRemoteAliasIsNotAssignedToEitherMac() {
        let store = makeStore()
        _ = store.openBrowser(for: "shared")
        let firstIdentity = BrowserWorkspaceIdentity(
            rawValue: "5:mac-a:shared",
            aliases: ["shared"]
        )
        let secondIdentity = BrowserWorkspaceIdentity(
            rawValue: "5:mac-b:shared",
            aliases: ["shared"]
        )

        store.reconcileWorkspaces([firstIdentity, secondIdentity])

        #expect(store.browser(for: firstIdentity) == nil)
        #expect(store.browser(for: secondIdentity) == nil)
        #expect(store.browser(for: "shared") == nil)
    }

    @Test func canonicalRawIdentityWinsOverAnotherWorkspacesMigrationAlias() {
        let store = makeStore()
        let anonymousBrowser = store.openBrowser(for: "shared")
        let anonymousIdentity = BrowserWorkspaceIdentity(rawValue: "shared")
        let scopedIdentity = BrowserWorkspaceIdentity(
            rawValue: "5:mac-b:shared",
            aliases: ["shared"]
        )

        store.reconcileWorkspaces([anonymousIdentity, scopedIdentity])

        #expect(store.browser(for: anonymousIdentity) === anonymousBrowser)
        #expect(store.browser(for: scopedIdentity) == nil)
    }

    @Test func identicalRemoteWorkspaceIDsRemainScopedToTheirOwningMacs() {
        let store = makeStore()
        let firstIdentity = BrowserWorkspaceIdentity(rawValue: "5:mac-a:shared")
        let secondIdentity = BrowserWorkspaceIdentity(rawValue: "5:mac-b:shared")

        let first = store.openBrowser(for: firstIdentity)
        let second = store.openBrowser(for: secondIdentity)

        #expect(first !== second)
        #expect(store.browser(for: firstIdentity) === first)
        #expect(store.browser(for: secondIdentity) === second)
    }

    @Test func reopenAfterCloseMakesFreshSurface() {
        let store = makeStore()
        let first = store.openBrowser(for: "ws-1")
        store.closeBrowser(for: "ws-1")
        let second = store.openBrowser(for: "ws-1")
        #expect(first !== second)
        #expect(second.id == .init(rawValue: "surface-2"))
    }

    @Test func staleQueuedArchiveGenerationCannotRestoreAfterScopeTransition() throws {
        let suiteName = "BrowserSurfaceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "cmux.mobile.browserSurfaces.v1"
        let scope = BrowserPersistenceScope(userID: "user-a", teamID: "team-a")
        let staleArchive = BrowserSurfaceArchive(
            scope: scope,
            surfaces: [
                BrowserSurfaceSnapshot(
                    workspaceID: "stale-workspace",
                    surfaceID: "stale-surface",
                    currentURL: "https://stale.example",
                    title: "Stale",
                    contentMode: "recommended",
                    isSelected: true
                ),
            ],
            generation: "prior-owner-generation"
        )
        defaults.set("current-owner-generation", forKey: "\(key).generation")
        defaults.set(try JSONEncoder().encode(staleArchive), forKey: key)

        let observer = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)
        observer.setPersistenceScope(scope)

        #expect(observer.browser(for: "stale-workspace") == nil)
        #expect(defaults.data(forKey: key) == nil)
    }

    @Test func legacyArchiveMigrationSurvivesRelaunchBeforeRewrite() throws {
        let suiteName = "BrowserSurfaceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "cmux.mobile.browserSurfaces.v1"

        var initialLaunch = BrowserArchiveGenerationState(defaults: defaults, archiveKey: key)
        #expect(initialLaunch.accepts(nil))
        initialLaunch.consumeLegacyRestore()

        let relaunchedBeforeRewrite = BrowserArchiveGenerationState(defaults: defaults, archiveKey: key)

        #expect(relaunchedBeforeRewrite.current == initialLaunch.current)
        #expect(relaunchedBeforeRewrite.accepts(nil))
    }

    @Test func successfulArchiveRewriteCompletesLegacyMigration() async throws {
        let suiteName = "BrowserSurfaceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "cmux.mobile.browserSurfaces.v1"
        let scope = BrowserPersistenceScope(userID: "user-a", teamID: "team-a")
        let archive = BrowserSurfaceArchive(
            scope: scope,
            surfaces: [
                BrowserSurfaceSnapshot(
                    workspaceID: "workspace-a",
                    surfaceID: "browser-a",
                    currentURL: "https://example.com",
                    title: "Example",
                    contentMode: "recommended",
                    isSelected: true
                ),
            ]
        )
        defaults.set(try JSONEncoder().encode(archive), forKey: key)
        let store = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)

        store.setPersistenceScope(scope)
        await store.flushPersistence()

        #expect(defaults.string(forKey: "\(key).generation.legacyMigration") == nil)
        let relaunched = BrowserArchiveGenerationState(defaults: defaults, archiveKey: key)
        #expect(!relaunched.accepts(nil))
        #expect(relaunched.accepts(relaunched.current))
    }

    @Test func archiveWriterCoalescesSupersededQueuedWrites() async throws {
        let suiteName = "BrowserSurfaceStoreTests.\(UUID().uuidString)"
        let key = "cmux.mobile.browserSurfaces.v1"
        let defaults = try #require(BlockingArchiveUserDefaults(suiteName: suiteName, archiveKey: key))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = BrowserSurfacePersistenceCoordinator(defaults: defaults, archiveKey: key)
        let scope = BrowserPersistenceScope(userID: "user", teamID: "team")
        let clientID = UUID()
        _ = coordinator.setScope(scope, for: clientID)

        coordinator.replaceSnapshots(
            ["workspace": Self.snapshot(title: "0")],
            for: clientID,
            scope: scope
        )
        await defaults.firstArchiveWriteStarted.wait()
        for index in 1 ... 100 {
            coordinator.replaceSnapshots(
                ["workspace": Self.snapshot(title: "\(index)")],
                for: clientID,
                scope: scope
            )
        }
        defaults.allowFirstArchiveWrite.signal()
        await coordinator.flush()

        #expect(defaults.archiveWriteCount <= 2)
        let data = try #require(defaults.data(forKey: key))
        let archive = try JSONDecoder().decode(BrowserSurfaceArchive.self, from: data)
        #expect(archive.surfaces.first?.title == "100")
    }

    private static func snapshot(title: String) -> BrowserSurfaceSnapshot {
        BrowserSurfaceSnapshot(
            workspaceID: "workspace",
            surfaceID: "browser",
            currentURL: "https://example.com",
            title: title,
            contentMode: "recommended",
            isSelected: true
        )
    }

    @Test func ownerlessLegacyArrayIsNeverClaimedByNextAccount() throws {
        let suiteName = "BrowserSurfaceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshots = [
            BrowserSurfaceSnapshot(
                workspaceID: "ws-1",
                surfaceID: "ownerless",
                currentURL: "https://private.example",
                title: "Private",
                contentMode: "recommended",
                isSelected: true
            ),
        ]
        defaults.set(try JSONEncoder().encode(snapshots), forKey: "cmux.mobile.browserSurfaces.v1")

        let store = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)
        store.setPersistenceScope(.init(userID: "user-a", teamID: nil))

        #expect(store.browser(for: "ws-1") == nil)
        #expect(defaults.data(forKey: "cmux.mobile.browserSurfaces.v1") == nil)
    }

    @Test func browserSnapshotsFilterUnrelatedAndDuplicateChanges() async throws {
        let store = makeStore()
        let first = store.openBrowser(for: "ws-a")
        let second = store.openBrowser(for: "ws-b")
        first.navigationDidFinish(url: URL(string: "https://a.example")!, title: "A")

        await confirmation("other workspace does not notify", expectedCount: 0) { didChange in
            withObservationTracking {
                _ = store.browserSnapshot(for: "ws-a")
            } onChange: {
                didChange()
            }
            second.navigationDidFinish(url: URL(string: "https://b.example")!, title: "B")
        }

        await confirmation("loading state does not notify", expectedCount: 0) { didChange in
            withObservationTracking {
                _ = store.browserSnapshot(for: "ws-a")
            } onChange: {
                didChange()
            }
            first.navigationDidStart()
        }

        await confirmation("equal durable state does not notify", expectedCount: 0) { didChange in
            withObservationTracking {
                _ = store.browserSnapshot(for: "ws-a")
            } onChange: {
                didChange()
            }
            first.navigationDidFinish(url: URL(string: "https://a.example")!, title: "A")
        }

        await confirmation("changed title notifies once") { didChange in
            withObservationTracking {
                _ = store.browserSnapshot(for: "ws-a")
            } onChange: {
                didChange()
            }
            first.pageTitleDidChange("A updated")
        }
    }

    @Test func browserSnapshotsTrackSelectionAndAliasMigration() throws {
        let store = makeStore()
        let browser = store.openBrowser(for: "remote")
        browser.navigationDidFinish(url: URL(string: "https://example.com")!, title: "Example")
        let initial = try #require(store.browserSnapshot(for: "remote"))
        #expect(initial.surfaceID == browser.id.rawValue)
        #expect(initial.title == "Example")
        #expect(initial.isSelected)

        store.showNonBrowserSurface(for: "remote")
        #expect(store.browserSnapshot(for: "remote")?.isSelected == false)
        _ = store.openBrowser(for: "remote")
        #expect(store.browserSnapshot(for: "remote")?.isSelected == true)

        let stable = BrowserWorkspaceIdentity(rawValue: "5:mac-a:remote", aliases: ["remote"])
        store.reconcileWorkspaces([stable])
        let migrated = try #require(store.browserSnapshot(for: stable))
        #expect(migrated.workspaceID == stable.rawValue)
        #expect(migrated.surfaceID == browser.id.rawValue)
        #expect(store.browserSnapshot(for: "remote") == nil)

        store.closeBrowser(for: stable)
        #expect(store.browserSnapshot(for: stable) == nil)
    }
}

private final class BlockingArchiveUserDefaults: UserDefaults, @unchecked Sendable {
    let firstArchiveWriteStarted = AsyncSignal()
    let allowFirstArchiveWrite = DispatchSemaphore(value: 0)

    private let archiveKey: String
    private let countLock = NSLock()
    private var writeCount = 0

    var archiveWriteCount: Int {
        countLock.withLock { writeCount }
    }

    init?(suiteName: String, archiveKey: String) {
        self.archiveKey = archiveKey
        super.init(suiteName: suiteName)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == archiveKey {
            let isFirst = countLock.withLock {
                writeCount += 1
                return writeCount == 1
            }
            if isFirst {
                let signal = firstArchiveWriteStarted
                Task { await signal.signal() }
                allowFirstArchiveWrite.wait()
            }
        }
        super.set(value, forKey: defaultName)
    }
}

private actor AsyncSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        isSignaled = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}
