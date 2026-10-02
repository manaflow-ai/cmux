import AppKit
import CmuxAuthRuntime
import CmuxCloud
import Foundation

/// Everything the New Machine sheet shows that comes from the server: the
/// plan limits (sizes, locks, upgrade plans), the active machine count, and
/// the network preset catalog.
struct NewMachineSheetData {
    /// Whether the machine list answered; `limits` and `activeCount` mean
    /// nothing until it has.
    var hasPlan: Bool
    /// The list endpoint's `limits`; nil when the server sent none.
    var limits: VMPlanLimits?
    var activeCount: Int
    /// The preset catalog; nil until it loads.
    var catalog: CloudNetworkPresetCatalog?
    /// The catalog request failed and no earlier answer exists, so the sheet
    /// shows the Network row as unavailable instead of loading.
    var catalogFailed: Bool

    var plan: MachinePlanSnapshot? {
        hasPlan ? MachineSnapshotBuilder.planSnapshot(activeCount: activeCount, limits: limits) : nil
    }
}

/// App-level, account-scoped cache of ``NewMachineSheetData`` so New Cloud
/// Machine (Cmd+Y) presents a fully populated sheet without waiting on the
/// network.
///
/// Ownership: created once at the composition root after `VMClient` is
/// bootstrapped (``bootstrap(auth:fetchPage:fetchCatalog:)``).
///
/// Warming: every authenticated account/team scope the auth coordinator
/// publishes (app launch with a restored session, sign-in, team switch)
/// starts a fetch. App activation revalidates when the data is older than
/// ``staleAfter``; presenting the sheet always revalidates in the background;
/// the Machines panel's list reads feed ``ingest(page:scope:)``.
///
/// Invalidation: a scope change (sign-out, account switch, team switch)
/// clears everything synchronously before any new fetch, and each result is
/// installed only if the scope it was fetched under is still current, so one
/// account's plan never reaches another account's sheet.
@MainActor
final class NewMachineSheetDataCache {
    typealias FetchPage = @MainActor @Sendable () async throws -> VMListPage
    typealias FetchCatalog = @MainActor @Sendable () async throws -> CloudNetworkPresetCatalog

    private(set) static var shared: NewMachineSheetDataCache?

    /// Older data is revalidated when the app becomes active.
    static let staleAfter: Duration = .seconds(60)

    private let currentScope: @MainActor () -> AuthenticatedTeamScope?
    private let scopes: @MainActor () -> AsyncStream<AuthenticatedTeamScope?>
    private let fetchPage: FetchPage
    private let fetchCatalog: FetchCatalog
    private let clock: ContinuousClock

    /// The scope the stored values belong to.
    private(set) var scope: AuthenticatedTeamScope?
    private var page: (limits: VMPlanLimits?, activeCount: Int)?
    private var catalog: CloudNetworkPresetCatalog?
    private var catalogFailed = false
    private var fetchedAt: ContinuousClock.Instant?

    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var scopeTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var listeners: [UUID: @MainActor (NewMachineSheetData) -> Void] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var waiterDeadlines: [UUID: Task<Void, Never>] = [:]

    init(
        currentScope: @escaping @MainActor () -> AuthenticatedTeamScope?,
        scopes: @escaping @MainActor () -> AsyncStream<AuthenticatedTeamScope?>,
        fetchPage: @escaping FetchPage,
        fetchCatalog: @escaping FetchCatalog,
        clock: ContinuousClock = ContinuousClock()
    ) {
        self.currentScope = currentScope
        self.scopes = scopes
        self.fetchPage = fetchPage
        self.fetchCatalog = fetchCatalog
        self.clock = clock
    }

    /// Builds the shared cache over the signed-in session and `VMClient`,
    /// and starts following the account scope.
    @discardableResult
    static func bootstrap(auth: AuthCoordinator) -> NewMachineSheetDataCache {
        let cache = NewMachineSheetDataCache(
            currentScope: { [weak auth] in auth?.authenticatedTeamScope },
            scopes: { [weak auth] in
                guard let auth else { return AsyncStream { $0.finish() } }
                return auth.authenticatedTeamScopes()
            },
            fetchPage: {
                guard let client = VMClient.shared else { throw VMClientError.notSignedIn }
                return try await client.listPage()
            },
            fetchCatalog: {
                guard let client = VMClient.shared else { throw VMClientError.notSignedIn }
                return try await client.networkPresets()
            }
        )
        cache.start(awaitingBootstrap: { [weak auth] in await auth?.awaitBootstrapped() })
        shared = cache
        return cache
    }

    func start(awaitingBootstrap: @escaping @MainActor () async -> Void = {}) {
        scopeTask?.cancel()
        scopeTask = Task { @MainActor [weak self] in
            await awaitingBootstrap()
            guard let stream = self?.scopes() else { return }
            for await scope in stream {
                guard !Task.isCancelled, let self else { return }
                self.adopt(scope: scope)
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfStale() }
        }
    }

    /// The sheet's data when it can present without waiting: the plan was
    /// fetched and the catalog either loaded or failed.
    var readyData: NewMachineSheetData? {
        guard let data = currentData, data.hasPlan, data.catalog != nil || data.catalogFailed else { return nil }
        return data
    }

    /// Whatever is cached for the current scope, complete or not.
    var currentData: NewMachineSheetData? {
        guard scope != nil, scope == currentScope(), page != nil || catalog != nil || catalogFailed else { return nil }
        return NewMachineSheetData(
            hasPlan: page != nil,
            limits: page?.limits,
            activeCount: page?.activeCount ?? 0,
            catalog: catalog,
            catalogFailed: catalogFailed
        )
    }

    /// Returns the ready data at once. Only a cold cache (the first seconds
    /// after sign-in, or a failed warm-up) waits, and never longer than
    /// `limit`: a slow control plane then gets a sheet with what is known,
    /// and the listener fills in the rest.
    func data(waitingAtMost limit: Duration = .seconds(1)) async -> NewMachineSheetData? {
        if let readyData { return readyData }
        guard refresh() else { return currentData }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[id] = continuation
            let clock = clock
            waiterDeadlines[id] = Task { @MainActor [weak self] in
                // Cancelled when the fetch answers first.
                guard (try? await clock.sleep(for: limit)) != nil else { return }
                self?.resumeWaiter(id)
            }
        }
        return currentData
    }

    private func resumeWaiter(_ id: UUID) {
        waiterDeadlines.removeValue(forKey: id)?.cancel()
        waiters.removeValue(forKey: id)?.resume()
    }

    private func resumeAllWaiters() {
        for id in Array(waiters.keys) { resumeWaiter(id) }
    }

    /// Calls `handler` with every update installed for the current scope.
    func addListener(_ handler: @escaping @MainActor (NewMachineSheetData) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = handler
        return id
    }

    func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    func refreshIfStale() {
        guard let fetchedAt else { refresh(); return }
        if clock.now - fetchedAt >= Self.staleAfter { refresh() }
    }

    /// Starts a fetch of the plan and the catalog unless one is running.
    /// Returns false when nobody is signed in, so no answer will come.
    @discardableResult
    func refresh() -> Bool {
        guard let scope = currentScope() else { return false }
        // A scope the stream has not delivered yet: adopting it drops the old
        // account's values and its in-flight fetch, and starts this one.
        guard scope == self.scope else {
            adopt(scope: scope)
            return refreshTask != nil
        }
        guard refreshTask == nil else { return true }
        let id = UUID()
        refreshID = id
        let fetchPage = fetchPage
        let fetchCatalog = fetchCatalog
        refreshTask = Task { @MainActor [weak self] in
            async let pageResult = Self.capture(fetchPage)
            async let catalogResult = Self.capture(fetchCatalog)
            let (fetchedPage, fetchedCatalog) = await (pageResult, catalogResult)
            guard let self, self.refreshID == id else { return }
            self.refreshTask = nil
            self.refreshID = nil
            defer { self.resumeAllWaiters() }
            guard !Task.isCancelled, self.isCurrent(scope) else { return }
            if case .success(let page) = fetchedPage {
                self.page = (page.limits, page.vms.count)
                self.fetchedAt = self.clock.now
            }
            switch fetchedCatalog {
            case .success(let catalog):
                self.catalog = catalog
                self.catalogFailed = false
            case .failure:
                // Keep an earlier catalog; only a cache that never had one
                // reports the row as unavailable.
                if self.catalog == nil { self.catalogFailed = true }
            }
            self.notify()
        }
        return true
    }

    /// Accepts a list page some other owner (the Machines panel) fetched
    /// under `scope`, so the count and limits stay current without a second
    /// request.
    func ingest(page: VMListPage, scope: AuthenticatedTeamScope?) {
        guard let scope, isCurrent(scope) else { return }
        self.page = (page.limits, page.vms.count)
        fetchedAt = clock.now
        notify()
    }

    /// The scope a caller should capture before a read it will ``ingest(page:scope:)``.
    var scopeForIngest: AuthenticatedTeamScope? { currentScope() }

    private func isCurrent(_ scope: AuthenticatedTeamScope) -> Bool {
        scope == self.scope && scope == currentScope()
    }

    private func adopt(scope: AuthenticatedTeamScope?) {
        guard scope != self.scope else {
            if scope != nil, page == nil { refresh() }
            return
        }
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        resumeAllWaiters()
        self.scope = scope
        page = nil
        catalog = nil
        catalogFailed = false
        fetchedAt = nil
        if scope != nil { refresh() }
    }

    private func notify() {
        guard let data = currentData else { return }
        for listener in listeners.values { listener(data) }
    }

    private static func capture<T: Sendable>(_ operation: @MainActor () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
}
