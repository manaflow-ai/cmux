import AppKit
import Combine
import Darwin
import Foundation
import CmuxSettings

private struct ComputerUseMenuBarActivityScan: Sendable {
    let activeRow: ComputerUseMenuBarRow?
    let activeState: ComputerUseDriverState?
    let hasRecentStateFiles: Bool
}

/// Builds the value-only snapshot consumed by the computer-use menu-bar controller.
@MainActor
final class ComputerUseMenuBarSnapshotStore: ObservableObject {
    @Published private(set) var snapshot: ComputerUseMenuBarSnapshot = .hidden

    private let liveAgentIndex: SharedLiveAgentIndex
    private let stateRepository: ComputerUseStateRepository
    private let stateDirectoryURL: URL
    private let configStore: JSONConfigStore
    private let showInMenuBarKey: JSONKey<Bool>
    private let workspaceTitle: @MainActor (UUID) -> String?
    private let featureEnabled: @MainActor () -> Bool
    private let refreshPolicy: ComputerUseMenuBarRefreshPolicy

    private var showInMenuBar: Bool
    private var refreshTask: Task<Void, Never>?
    private var expiryRefreshTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var directoryWatchSource: DispatchSourceFileSystemObject?
    // DispatchSource requires a delivery queue; every mutation hops back to MainActor.
    private let directoryWatchQueue = DispatchQueue(label: "com.cmuxterm.app.computerUseStateWatch")
    private var refreshGeneration = 0
    private var liveRows: [ComputerUseMenuBarRow] = []
    private var liveRowsNeedRebuild = true

    init(
        liveAgentIndex: SharedLiveAgentIndex,
        stateRepository: ComputerUseStateRepository,
        stateDirectoryURL: URL,
        configStore: JSONConfigStore,
        showInMenuBarKey: JSONKey<Bool>,
        workspaceTitle: @escaping @MainActor (UUID) -> String?,
        featureEnabled: @escaping @MainActor () -> Bool,
        refreshPolicy: ComputerUseMenuBarRefreshPolicy = .live
    ) {
        self.liveAgentIndex = liveAgentIndex
        self.stateRepository = stateRepository
        self.stateDirectoryURL = stateDirectoryURL
        self.configStore = configStore
        self.showInMenuBarKey = showInMenuBarKey
        self.workspaceTitle = workspaceTitle
        self.featureEnabled = featureEnabled
        self.refreshPolicy = refreshPolicy
        self.showInMenuBar = configStore.snapshotValue(for: showInMenuBarKey)
    }

    deinit {
        refreshTask?.cancel()
        expiryRefreshTask?.cancel()
        settingsTask?.cancel()
        directoryWatchSource?.cancel()
    }

    func start() {
        guard settingsTask == nil else { return }

        NotificationCenter.default.publisher(for: .sharedLiveAgentIndexDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.liveRowsNeedRebuild = true
                    self?.refresh()
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .cmuxFeatureFlagsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)

        settingsTask = Task { [weak self, configStore, showInMenuBarKey] in
            for await value in configStore.values(for: showInMenuBarKey) {
                guard !Task.isCancelled else { return }
                self?.showInMenuBar = value
                self?.refresh()
            }
        }
        liveRowsNeedRebuild = true
        refresh()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        expiryRefreshTask?.cancel()
        expiryRefreshTask = nil
        settingsTask?.cancel()
        settingsTask = nil
        cancellables.removeAll()
        directoryWatchSource?.cancel()
        directoryWatchSource = nil
    }

    func refresh() {
        let currentShowInMenuBar = showInMenuBar
        let currentFeatureEnabled = featureEnabled()
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        expiryRefreshTask?.cancel()
        expiryRefreshTask = nil

        guard let reloadDeadline = refreshPolicy.reloadDeadline(
            forEventAt: Date(),
            featureEnabled: currentFeatureEnabled,
            showInMenuBar: currentShowInMenuBar
        ) else {
            hideSnapshot(
                showInMenuBar: currentShowInMenuBar,
                featureEnabled: currentFeatureEnabled
            )
            return
        }
        if liveRowsNeedRebuild {
            rebuildLiveRows()
            liveRowsNeedRebuild = false
        }
        guard !liveRows.isEmpty else {
            hideSnapshot(
                showInMenuBar: currentShowInMenuBar,
                featureEnabled: currentFeatureEnabled
            )
            return
        }
        startWatchingStateDirectory()

        refreshTask = Task { [weak self] in
            let delay = max(0, reloadDeadline.timeIntervalSinceNow)
            do {
                // A bounded, cancellable debounce is the intended behavior: one
                // atomic state write can emit several filesystem events.
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard
                let self,
                !Task.isCancelled,
                generation == self.refreshGeneration
            else {
                return
            }

            // Live-agent changes rebuild this value snapshot separately.
            // Driver-state writes therefore do no workspace-title resolution or
            // live-index enumeration on the main actor.
            let pending = self.liveRows

            let repository = self.stateRepository
            let directoryURL = self.stateDirectoryURL

            let result = await withTaskGroup(of: ComputerUseMenuBarActivityScan?.self) { group in
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return nil }
                    let scopes = pending.map { row in
                        ComputerUseSessionScope(
                            id: row.id,
                            driverSessionID: ComputerUseSessionScope.driverSessionID(
                                surfaceID: row.surfaceID
                            )
                        )
                    }
                    let rootsByScopeID = Dictionary(
                        uniqueKeysWithValues: pending.map {
                            ($0.id, $0.rootProcessIdentities)
                        }
                    )
                    let scan = repository.scan(
                        directoryURL: directoryURL,
                        sessions: scopes,
                        now: Date()
                    ) { scope, state in
                        guard let roots = rootsByScopeID[scope.id] else {
                            return false
                        }
                        return state.belongsToProcessTree(
                            rootProcessIdentities: roots
                        )
                    }
                    guard !Task.isCancelled else { return nil }
                    let projection = ComputerUseMenuBarScanResult(
                        rows: pending,
                        scan: scan
                    )
                    let active = projection.mostRecentlyActive { _, _ in true }
                    return ComputerUseMenuBarActivityScan(
                        activeRow: active?.row,
                        activeState: active?.state,
                        hasRecentStateFiles: scan.hasRecentStateFiles
                    )
                }
                return await group.next() ?? nil
            }

            guard let result, !Task.isCancelled, generation == self.refreshGeneration else { return }
            let rows = [result.activeRow].compactMap { row -> ComputerUseMenuBarRow? in
                guard
                    let row,
                    let state = result.activeState,
                    let pid = pid_t(exactly: state.targetPID),
                    let application = NSRunningApplication(processIdentifier: pid),
                    let identity = ComputerUseTargetIdentity(state: state, runningApplication: application)
                else {
                    return nil
                }
                return row.withTarget(
                    identity: identity,
                    stateWriterIdentity: state.writerProcessIdentity
                )
            }
            self.snapshot = ComputerUseMenuBarSnapshot(
                rows: rows,
                hasRecentStateFiles: result.hasRecentStateFiles,
                showInMenuBar: currentShowInMenuBar,
                featureEnabled: currentFeatureEnabled
            )
            if !rows.isEmpty, let activeState = result.activeState {
                self.scheduleExpiryRefresh(
                    lastActionAt: activeState.lastActionAt,
                    generation: generation
                )
            }
        }
    }

    private func hideSnapshot(showInMenuBar: Bool, featureEnabled: Bool) {
        stopWatchingStateDirectory()
        refreshTask = nil
        snapshot = ComputerUseMenuBarSnapshot(
            rows: [],
            hasRecentStateFiles: false,
            showInMenuBar: showInMenuBar,
            featureEnabled: featureEnabled
        )
    }

    private func rebuildLiveRows() {
        liveRows = (liveAgentIndex.index?.liveEntries() ?? []).compactMap { pair in
            let snapshot = pair.entry.snapshot
            let workspaceName = workspaceTitle(pair.panelKey.workspaceId)
                ?? String(
                    localized: "computerUse.menu.unknownWorkspace",
                    defaultValue: "Unknown Workspace"
                )
            guard let liveSession = ComputerUseLiveDriverSession(
                workspaceID: pair.panelKey.workspaceId,
                surfaceID: pair.panelKey.panelId,
                entry: pair.entry
            ) else { return nil }
            return ComputerUseMenuBarRow(
                id: liveSession.logicalSessionID,
                title: String(
                    localized: "computerUse.menu.sessionTitle",
                    defaultValue: "\(snapshot.kind.displayName) · \(workspaceName)"
                ),
                sessionID: snapshot.sessionId,
                workspaceID: pair.panelKey.workspaceId,
                surfaceID: pair.panelKey.panelId,
                rootProcessIdentities: liveSession.rootProcessIdentities,
                targetIdentity: nil,
                stateWriterIdentity: nil
            )
        }
    }

    private func scheduleExpiryRefresh(lastActionAt: Date, generation: Int) {
        let deadline = refreshPolicy.stateExpirationDeadline(
            lastActionAt: lastActionAt,
            recentActivityInterval: stateRepository.recentActivityInterval
        )
        expiryRefreshTask?.cancel()
        expiryRefreshTask = Task { @MainActor [weak self] in
            let delay = max(0, deadline.timeIntervalSinceNow)
            do {
                // This bounded, cancellable delay is the state-freshness
                // deadline. It fires once so an idle session disappears even
                // when no later filesystem event arrives.
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard
                let self,
                !Task.isCancelled,
                generation == self.refreshGeneration
            else {
                return
            }
            self.expiryRefreshTask = nil
            self.refresh()
        }
    }

    private func startWatchingStateDirectory() {
        guard directoryWatchSource == nil else { return }
        try? FileManager.default.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true
        )
        let descriptor = open(stateDirectoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete],
            queue: directoryWatchQueue
        )
        source.setEventHandler(handler: Self.makeDirectoryWatchEventHandler(
            source: source,
            store: self
        ))
        source.setCancelHandler(handler: Self.makeDirectoryWatchCancelHandler(
            descriptor: descriptor
        ))
        source.resume()
        directoryWatchSource = source
    }

    /// DispatchSource delivers on its own queue. Build the callback outside the
    /// main actor so Swift 6 does not trap before the explicit actor hop.
    nonisolated private static func makeDirectoryWatchEventHandler(
        source: DispatchSourceFileSystemObject,
        store: ComputerUseMenuBarSnapshotStore
    ) -> @Sendable () -> Void {
        { [weak source, weak store] in
            guard let source else { return }
            let events = source.data
            Task { @MainActor [weak store] in
                store?.handleDirectoryWatchEvent(
                    events,
                    from: source
                )
            }
        }
    }

    nonisolated private static func makeDirectoryWatchCancelHandler(
        descriptor: Int32
    ) -> @Sendable () -> Void {
        { Darwin.close(descriptor) }
    }

    private func handleDirectoryWatchEvent(
        _ events: DispatchSource.FileSystemEvent,
        from source: DispatchSourceFileSystemObject
    ) {
        guard directoryWatchSource === source else { return }
        if events.contains(.delete) || events.contains(.rename) {
            source.cancel()
            directoryWatchSource = nil
            startWatchingStateDirectory()
        }
        refresh()
    }

    private func stopWatchingStateDirectory() {
        directoryWatchSource?.cancel()
        directoryWatchSource = nil
    }
}
