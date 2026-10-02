import AppKit
import CmuxCloud
import CmuxCloudMachines
import Foundation
import Observation

/// The machine fleet as the status item and the main-menu Cloud menu show it.
///
/// Menus do not poll. Opening either menu asks for a refresh; a read younger
/// than `freshness` is reused, so the menu opens on the last known fleet and
/// updates in place when the read lands. Team switches and sign-out drop the
/// fleet and discard reads that were started for the previous scope.
@MainActor
@Observable
final class CloudMenuModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(MachinesPanelViewModel.CloudListProblem)
    }

    private(set) var machines: [MachineSnapshot] = []
    private(set) var loadState: LoadState = .idle
    private(set) var fleetPage: VMListPage?
    /// Bumped on every published change so AppKit menus can rebuild while open.
    private(set) var revision: UInt64 = 0
    /// Cloud feature availability, observable so the main-menu Cloud menu
    /// appears and disappears with the feature flag.
    private(set) var isFeatureEnabled = false

    static let freshness: Duration = .seconds(20)
    private static let refreshRetryDelays: [Duration] = [.milliseconds(100), .milliseconds(250)]
    @ObservationIgnored private let listMachines: @MainActor () async throws -> VMListPage
    @ObservationIgnored private let retryClock: any Clock<Duration>
    @ObservationIgnored private let isAvailable: @MainActor () -> Bool
    @ObservationIgnored private let pinStore: @MainActor () -> CloudMachinePinStore?
    /// The account and team a read belongs to; the pin store's scope by default.
    @ObservationIgnored private let scope: @MainActor () -> String?
    @ObservationIgnored private var lastLoadedAt: ContinuousClock.Instant?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pageWaiters: [UUID: CheckedContinuation<VMListPage?, Never>] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var featureObserver: CloudFeatureAvailabilityObserver?
    @ObservationIgnored private let mainMenu: @MainActor () -> NSMenu?

    init(
        center: NotificationCenter = .default,
        listMachines: (@MainActor () async throws -> VMListPage)? = nil,
        retryClock: any Clock<Duration> = ContinuousClock(),
        isAvailable: @escaping @MainActor () -> Bool = {
            CloudMachinesFeature.isEnabled && AppDelegate.shared?.auth?.accountFlow.isAuthenticated == true
        },
        pinStore: @escaping @MainActor () -> CloudMachinePinStore? = { AppDelegate.shared?.cloudMachinePinStore },
        scope: (@MainActor () -> String?)? = nil,
        isFeatureEnabled: @escaping @MainActor () -> Bool = { CloudMachinesFeature.isEnabled },
        mainMenu: @escaping @MainActor () -> NSMenu? = { NSApp?.mainMenu }
    ) {
        self.retryClock = retryClock
        self.listMachines = listMachines ?? {
            guard let client = VMClient.shared as VMClient? else { throw VMClientError.notSignedIn }
            return try await client.listPage()
        }
        self.isAvailable = isAvailable
        self.pinStore = pinStore
        self.scope = scope ?? { pinStore()?.scopeIdentifier }
        self.mainMenu = mainMenu
        observers = [Notification.Name.cmuxCloudVMAccessDidEnd, .cmuxCloudTeamScopeDidChange].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Posted on the main queue by the auth and team-scope owners.
                MainActor.assumeIsolated { self?.reset() }
            }
        }
        // The main-menu Cloud menu has no willOpen hook; opening any main-menu
        // title refreshes a stale fleet, the same seam the History menu uses.
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            guard var root = notification.object as? NSMenu else { return }
            while let parent = root.supermenu { root = parent }
            let rootID = ObjectIdentifier(root)
            // NSMenu tracking notifications are delivered on the main run loop.
            MainActor.assumeIsolated {
                guard let self, let mainMenu = self.mainMenu(), ObjectIdentifier(mainMenu) == rootID else { return }
                self.menuWillOpen()
            }
        })
        featureObserver = CloudFeatureAvailabilityObserver(notificationCenter: center, isEnabled: isFeatureEnabled) { [weak self] enabled in
            guard let self else { return }
            self.isFeatureEnabled = enabled
            if !enabled { self.reset() }
        }
    }

    /// Returns the authoritative fleet page used to build Cloud creation UI.
    /// Callers wait on the shared refresh owner instead of inventing a second
    /// readiness or retry policy in their presenter.
    func fleetPageForPresentation() async -> VMListPage? {
        guard !Task.isCancelled else { return nil }
        if let fleetPage { return fleetPage }
        guard isAvailable() else { return nil }
        let waiterID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                pageWaiters[waiterID] = continuation
                if let fleetPage {
                    pageWaiters.removeValue(forKey: waiterID)?.resume(returning: fleetPage)
                } else {
                    if task == nil { refresh() }
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.pageWaiters.removeValue(forKey: waiterID)?.resume(returning: nil)
            }
        })
    }

    func menuWillOpen() {
        guard isAvailable() else { reset(); return }
        if task != nil { return }
        if loadState == .loaded, let lastLoadedAt,
           ContinuousClock.now - lastLoadedAt < Self.freshness { return }
        refresh()
    }

    /// Reads the fleet now (Retry, or a verb that changed it).
    func refresh() {
        guard isAvailable() else { reset(); return }
        task?.cancel()
        let requested = generation
        let scope = self.scope()
        if machines.isEmpty || loadState != .loaded { publish(loadState: .loading) }
        task = Task { [weak self, listMachines, retryClock] in
            var result: Result<VMListPage, Error> = .failure(CancellationError())
            for attempt in 0...Self.refreshRetryDelays.count {
                do {
                    result = .success(try await listMachines())
                    break
                } catch {
                    result = .failure(error)
                    if let error = error as? VMClientError, case .notSignedIn = error { break }
                    guard attempt < Self.refreshRetryDelays.count, !Task.isCancelled else { break }
                    do { try await retryClock.sleep(for: Self.refreshRetryDelays[attempt]) }
                    catch { return }
                }
            }
            guard !Task.isCancelled, let self, self.generation == requested else { return }
            self.task = nil
            // The team was confirmed or switched while this read was in flight
            // (the first confirmation posts no scope notification): read again
            // for the current scope instead of showing the old one.
            guard self.scope() == scope else { self.refresh(); return }
            self.apply(result)
        }
    }

    private func apply(_ result: Result<VMListPage, Error>) {
        switch result {
        case .success(let page):
            fleetPage = page
            let waiters = pageWaiters
            pageWaiters.removeAll()
            for waiter in waiters.values { waiter.resume(returning: page) }
            let windowDays = page.limits?.freeAccessWindowDays ?? 0
            let snapshots = page.vms.map { MachineSnapshotBuilder.snapshot(from: $0, freeAccessWindowDays: windowDays) }
            lastLoadedAt = ContinuousClock.now
            publish(machines: ordered(snapshots), loadState: .loaded)
        case .failure(let error as VMClientError):
            if case .notSignedIn = error { reset(); return }
            finishPageWaiters()
            publish(loadState: .failed(MachinesPanelViewModel.classifyListFailure(error)))
        case .failure:
            finishPageWaiters()
            publish(loadState: .failed(.unreachable))
        }
    }

    private func finishPageWaiters() {
        let waiters = pageWaiters
        pageWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(returning: nil) }
    }

    /// Same order and pins as the Cloud sidebar.
    private func ordered(_ snapshots: [MachineSnapshot]) -> [MachineSnapshot] {
        guard let store = pinStore(), store.scopeIdentifier != nil else { return snapshots }
        let byID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return store.orderedMachineIDs(snapshots.map(\.id)).compactMap { id in
            guard var snapshot = byID[id] else { return nil }
            snapshot.isPinned = store.isPinned(id)
            return snapshot
        }
    }

    private func reset() {
        generation &+= 1
        task?.cancel()
        task = nil
        lastLoadedAt = nil
        fleetPage = nil
        let waiters = pageWaiters
        pageWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(returning: nil) }
        guard !machines.isEmpty || loadState != .idle else { return }
        publish(machines: [], loadState: .idle)
    }

    private func publish(machines: [MachineSnapshot]? = nil, loadState: LoadState) {
        if let machines { self.machines = machines }
        self.loadState = loadState
        revision &+= 1
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// The one fleet both Cloud menus read.
    static let shared = CloudMenuModel()

    static let didChangeNotification = Notification.Name("cmux.cloudMenuModel.didChange")
}
