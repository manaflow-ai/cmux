import Combine
import Darwin
import Foundation
import CmuxSettings

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
    private let onCapableSessionStarted: @MainActor () -> Void

    private var showInMenuBar: Bool
    private var refreshTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var directoryWatchSource: DispatchSourceFileSystemObject?
    // DispatchSource requires a delivery queue; every mutation hops back to MainActor.
    private let directoryWatchQueue = DispatchQueue(label: "com.cmuxterm.app.computerUseStateWatch")
    private var previousCapableSessionIDs: Set<String> = []
    private var refreshGeneration = 0

    init(
        liveAgentIndex: SharedLiveAgentIndex,
        stateRepository: ComputerUseStateRepository,
        stateDirectoryURL: URL,
        configStore: JSONConfigStore,
        showInMenuBarKey: JSONKey<Bool>,
        workspaceTitle: @escaping @MainActor (UUID) -> String?,
        featureEnabled: @escaping @MainActor () -> Bool,
        onCapableSessionStarted: @escaping @MainActor () -> Void
    ) {
        self.liveAgentIndex = liveAgentIndex
        self.stateRepository = stateRepository
        self.stateDirectoryURL = stateDirectoryURL
        self.configStore = configStore
        self.showInMenuBarKey = showInMenuBarKey
        self.workspaceTitle = workspaceTitle
        self.featureEnabled = featureEnabled
        self.onCapableSessionStarted = onCapableSessionStarted
        self.showInMenuBar = configStore.snapshotValue(for: showInMenuBarKey)
    }

    deinit {
        refreshTask?.cancel()
        settingsTask?.cancel()
        directoryWatchSource?.cancel()
    }

    func start() {
        guard settingsTask == nil else { return }

        NotificationCenter.default.publisher(for: .sharedLiveAgentIndexDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .cmuxFeatureFlagsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &cancellables)

        settingsTask = Task { [weak self, configStore, showInMenuBarKey] in
            for await value in configStore.values(for: showInMenuBarKey) {
                guard !Task.isCancelled else { return }
                self?.showInMenuBar = value
                self?.refresh()
            }
        }
        startWatchingStateDirectory()
        refresh()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        settingsTask?.cancel()
        settingsTask = nil
        cancellables.removeAll()
        directoryWatchSource?.cancel()
        directoryWatchSource = nil
    }

    func refresh() {
        let entries = liveAgentIndex.currentIndexSchedulingRefresh()?.liveEntries() ?? []
        let pending = entries.map { pair in
            let snapshot = pair.entry.snapshot
            let rootPIDs = pair.entry.agentProcessIDs.isEmpty ? pair.entry.processIDs : pair.entry.agentProcessIDs
            let workspaceName = workspaceTitle(pair.panelKey.workspaceId)
                ?? String(localized: "computerUse.menu.unknownWorkspace", defaultValue: "Unknown Workspace")
            let rowID = [
                snapshot.kind.rawValue,
                snapshot.sessionId,
                pair.panelKey.workspaceId.uuidString,
                pair.panelKey.panelId.uuidString,
            ].joined(separator: "|")
            let row = ComputerUseMenuBarRow(
                id: rowID,
                title: String(
                    localized: "computerUse.menu.sessionTitle",
                    defaultValue: "\(snapshot.kind.displayName) · \(workspaceName)"
                ),
                sessionID: snapshot.sessionId,
                workspaceID: pair.panelKey.workspaceId,
                surfaceID: pair.panelKey.panelId,
                targetPID: nil
            )
            return (
                row: row,
                rootPIDs: rootPIDs,
                computerUseCapable: snapshot.kind == .claude || snapshot.kind == .codex
            )
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        let repository = stateRepository
        let directoryURL = stateDirectoryURL
        let currentShowInMenuBar = showInMenuBar
        let currentFeatureEnabled = featureEnabled()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let processSnapshot = CmuxTopProcessSnapshot.capture(
                    includeProcessDetails: false,
                    includeCMUXScope: false
                )
                let scopes = pending.map { item in
                    ComputerUseSessionProcessScope(
                        id: item.row.id,
                        sessionID: item.row.sessionID,
                        processIDs: processSnapshot.expandedPIDs(rootPIDs: item.rootPIDs)
                    )
                }
                let scan = repository.scan(
                    directoryURL: directoryURL,
                    sessions: scopes,
                    now: Date()
                )
                let rows = pending.map { item in
                    item.row.withTargetPID(scan.newestStateByScopeID[item.row.id]?.targetPID)
                }
                let capableSessionIDs = Set(
                    pending.filter { $0.computerUseCapable }.map { $0.row.id }
                )
                return (rows: rows, scan: scan, capableSessionIDs: capableSessionIDs)
            }.value

            guard let self, !Task.isCancelled, generation == self.refreshGeneration else { return }
            self.snapshot = ComputerUseMenuBarSnapshot(
                rows: result.rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
                hasRecentStateFiles: result.scan.hasRecentStateFiles,
                showInMenuBar: currentShowInMenuBar,
                featureEnabled: currentFeatureEnabled
            )
            let newlyStarted = result.capableSessionIDs.subtracting(self.previousCapableSessionIDs)
            self.previousCapableSessionIDs = result.capableSessionIDs
            if currentFeatureEnabled, !newlyStarted.isEmpty {
                self.onCapableSessionStarted()
            }
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
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        directoryWatchSource = source
    }
}
