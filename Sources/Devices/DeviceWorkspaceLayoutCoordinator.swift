import CmuxCore
import Foundation

/// Orders local layout intents and projects the owning Mac's accepted snapshots.
@MainActor
final class DeviceWorkspaceLayoutCoordinator {
    private struct Intent {
        let workspaceID: UUID
        let layout: DeviceWorkspaceLayoutNode
        let requestID: String
    }
    private struct Delivery: Equatable {
        let revision: String
        let panels: Set<UUID>
        let sourceIDs: Set<String>
    }

    private let machine: SurfaceMachineID
    private weak var catalog: SurfaceCatalog?
    private let workspace: @MainActor (UUID) -> Workspace?
    private let request: @MainActor (String, [String: Any]) async throws -> Data
    private let refresh: @MainActor () async -> Void
    private let isConnected: @MainActor () -> Bool
    private let didAccept: @MainActor () -> Void
    private let notificationCenter: NotificationCenter
    // Only the main actor mutates registrations; deinit has exclusive ownership
    // and calls NotificationCenter's thread-safe removal API for opaque tokens.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private(set) var snapshots: [String: DeviceWorkspaceLayoutSnapshot] = [:]
    private var sequences: [String: UInt64] = [:]
    private var pending: [String: Intent] = [:]
    private var writers: [String: Task<Void, Never>] = [:]
    private var deliveries: [UUID: Delivery] = [:]
    private var metadataRefreshes: [String: String] = [:]
    private var fetchRequested: Set<String> = []
    private var suspended: Set<UUID> = []
    private var deferredNativeChanges: Set<UUID> = []
    private var reconcileTask: Task<Void, Never>?
    private var reconcileRequested = false
    private var wasConnected = false
    private var stopped = false

    init(
        machine: SurfaceMachineID,
        catalog: SurfaceCatalog,
        workspace: @escaping @MainActor (UUID) -> Workspace?,
        request: @escaping @MainActor (String, [String: Any]) async throws -> Data,
        refresh: @escaping @MainActor () async -> Void,
        isConnected: @escaping @MainActor () -> Bool,
        didAccept: @escaping @MainActor () -> Void,
        notificationCenter: NotificationCenter = .default
    ) {
        self.machine = machine
        self.catalog = catalog
        self.workspace = workspace
        self.request = request
        self.refresh = refresh
        self.isConnected = isConnected
        self.didAccept = didAccept
        self.notificationCenter = notificationCenter
        wasConnected = isConnected()
        observers.append(notificationCenter.addObserver(forName: .workspacePaneGeometryDidChange, object: nil, queue: .main) { [weak self] notification in
            guard let id = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            let external = notification.userInfo?[DeviceWorkspaceLayoutHost.externalGeometryKey] as? Bool ?? false
            let layout = notification.userInfo?[DeviceWorkspaceLayoutHost.layoutGeometryKey] as? DeviceWorkspaceLayoutNode
            Task { @MainActor [weak self] in
                self?.nativeLayoutChanged(workspaceID: id, capturedLayout: layout, isExternal: external)
            }
        })
        observers.append(notificationCenter.addObserver(forName: SurfaceCatalog.didChangeNotification, object: catalog, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleReconcile() }
        })
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }

    func stop() {
        stopped = true
        reconcileTask?.cancel()
        reconcileTask = nil
        for task in writers.values { task.cancel() }
        writers.removeAll()
        pending.removeAll()
        snapshots.removeAll()
        sequences.removeAll()
        deliveries.removeAll()
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    func connectionChanged() {
        let connected = isConnected()
        guard connected != wasConnected else { return }
        wasConnected = connected
        sequences.removeAll()
        metadataRefreshes.removeAll()
        deliveries.removeAll()
        if !connected {
            for task in writers.values { task.cancel() }
            pending.removeAll()
        } else {
            scheduleReconcile()
        }
    }

    func accept(_ snapshot: DeviceWorkspaceLayoutSnapshot) {
        guard !stopped, UUID(uuidString: snapshot.workspaceID) != nil,
              (try? snapshot.layout.validatedSurfaceIDs()) != nil,
              snapshot.sequence >= sequences[snapshot.workspaceID, default: 0] else { return }
        let changed = snapshots[snapshot.workspaceID] != snapshot
        snapshots[snapshot.workspaceID] = snapshot
        sequences[snapshot.workspaceID] = snapshot.sequence
        if changed { didAccept() }
        scheduleReconcile()
    }

    func beginMutation(_ token: UUID) { suspended.insert(token) }

    func refreshRequested() {
        fetchRequested.formUnion(snapshots.keys)
        metadataRefreshes.removeAll()
        deliveries.removeAll()
        scheduleReconcile()
    }

    func endMutation(_ token: UUID) {
        suspended.remove(token)
        guard suspended.isEmpty else { return }
        let changed = deferredNativeChanges
        deferredNativeChanges.removeAll()
        for id in changed { nativeLayoutChanged(workspaceID: id) }
        scheduleReconcile()
    }

    /// Consumes native layout events, never terminal bytes or typing updates.
    func nativeLayoutChanged(workspaceID: UUID, capturedLayout: DeviceWorkspaceLayoutNode? = nil, isExternal: Bool = false) {
        guard !isExternal, !stopped, let target = target(for: workspaceID),
              let native = capturedLayout ?? workspace(workspaceID)?.deviceWorkspaceLayoutSnapshot(),
              let mapped = try? native.remappingSurfaceIDs(target.mapping),
              let ids = try? mapped.validatedSurfaceIDs() else { return }
        guard suspended.isEmpty else { deferredNativeChanges.insert(workspaceID); return }
        if let accepted = snapshots[target.remoteID],
           Set(ids) != Set((try? accepted.layout.validatedSurfaceIDs()) ?? []) { return }
        if writers[target.remoteID] == nil, pending[target.remoteID] == nil,
           snapshots[target.remoteID]?.layout.hasSameArrangement(as: mapped) == true { return }
        guard isConnected() else {
            deliveries[workspaceID] = nil
            return
        }
        pending[target.remoteID] = Intent(workspaceID: workspaceID, layout: mapped, requestID: UUID().uuidString)
        startWriter(for: target.remoteID)
    }

    private func startWriter(for remoteID: String) {
        guard writers[remoteID] == nil, !stopped else { return }
        writers[remoteID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.writers[remoteID] = nil
                if self.pending[remoteID] != nil, self.isConnected(), !self.stopped {
                    self.startWriter(for: remoteID)
                }
                self.scheduleReconcile()
            }
            while let intent = self.pending.removeValue(forKey: remoteID) {
                do {
                    try Task.checkCancellation()
                    if self.sequences[remoteID] == nil || self.fetchRequested.remove(remoteID) != nil {
                        try await self.fetch(remoteID)
                    }
                    guard let accepted = self.snapshots[remoteID], !accepted.revision.isEmpty else {
                        throw DeviceLinkError.malformedResponse("device.workspace.layout")
                    }
                    if accepted.layout.hasSameArrangement(as: intent.layout) { continue }
                    let layout = try JSONSerialization.jsonObject(with: JSONEncoder().encode(intent.layout))
                    let data = try await self.request("device.workspace.layout.apply", [
                        "workspace_id": remoteID, "request_id": intent.requestID,
                        "base_revision": accepted.revision, "layout": layout
                    ])
                    try Task.checkCancellation()
                    self.accept(try JSONDecoder().decode(DeviceWorkspaceLayoutSnapshot.self, from: data))
                } catch {
                    guard !Task.isCancelled, !self.stopped else { return }
                    // Recover the authoritative layout before rolling back. A
                    // newer queued gesture retains its own intent and revision.
                    try? await self.fetch(remoteID)
                    self.deliveries[intent.workspaceID] = nil
                    if self.pending[remoteID] == nil {
                        self.workspace(intent.workspaceID)?.presentDeviceLayoutFailure(error, machine: self.machine)
                    }
                }
            }
        }
    }

    private func fetch(_ remoteID: String) async throws {
        let data = try await request("device.workspace.layout", ["workspace_id": remoteID])
        try Task.checkCancellation()
        let snapshot = try JSONDecoder().decode(DeviceWorkspaceLayoutSnapshot.self, from: data)
        guard snapshot.workspaceID == remoteID else { throw DeviceLinkError.malformedResponse("device.workspace.layout") }
        accept(snapshot)
    }

    private func target(for id: UUID) -> (remoteID: String, mapping: [String: String], projections: [SurfaceProjection])? {
        guard let catalog, let native = workspace(id) else { return nil }
        let projections = catalog.projections.filter { $0.workspaceID == id && $0.resource.machine == machine }
        guard !projections.isEmpty, Set(projections.map(\.panelID)) == Set(native.panels.keys) else { return nil }
        let remoteIDs = Set(projections.compactMap(\.remoteWorkspaceID))
        guard remoteIDs.count == 1, let remoteID = remoteIDs.first,
              projections.allSatisfy({ $0.remoteWorkspaceID == remoteID }) else { return nil }
        let mapping = Dictionary(projections.map { ($0.panelID.uuidString, $0.resource.key) }, uniquingKeysWith: { first, _ in first })
        return (remoteID, mapping, Array(projections))
    }

    private func scheduleReconcile() {
        guard !stopped, isConnected() else { return }
        reconcileRequested = true
        guard reconcileTask == nil, suspended.isEmpty else { return }
        reconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.reconcileTask = nil }
            while self.reconcileRequested, !Task.isCancelled, self.suspended.isEmpty {
                self.reconcileRequested = false
                await self.reconcile()
            }
        }
    }

    private func reconcile() async {
        guard let catalog else { return }
        let localIDs = Set(catalog.projections.filter { $0.resource.machine == machine }.map(\.workspaceID))
        deliveries = deliveries.filter { localIDs.contains($0.key) }
        for id in localIDs {
            guard !Task.isCancelled, let target = target(for: id), let native = workspace(id),
                  writers[target.remoteID] == nil, pending[target.remoteID] == nil else { continue }
            do {
                if sequences[target.remoteID] == nil || fetchRequested.remove(target.remoteID) != nil {
                    try await fetch(target.remoteID)
                }
                guard let snapshot = snapshots[target.remoteID] else { continue }
                let sourceIDs = try snapshot.layout.validatedSurfaceIDs()
                if let previous = deliveries[id],
                   !previous.sourceIDs.intersection(sourceIDs).isSubset(of: Set(target.mapping.values)) {
                    // Closing a local mirror tab detaches that view; it must
                    // neither kill nor silently reopen the source terminal.
                    continue
                }
                let delivery = Delivery(revision: snapshot.revision, panels: Set(native.panels.keys), sourceIDs: Set(sourceIDs))
                if deliveries[id] == delivery { continue }
                if metadataRefreshes[target.remoteID] != snapshot.revision,
                   sourceIDs.contains(where: { catalog.resources[SurfaceResourceID(machine: machine, kind: .terminal, key: $0)] == nil }) {
                    metadataRefreshes[target.remoteID] = snapshot.revision
                    await refresh()
                }
                guard !Task.isCancelled, suspended.isEmpty, snapshots[target.remoteID] == snapshot,
                      writers[target.remoteID] == nil, pending[target.remoteID] == nil else { continue }
                let wanted = sourceIDs.map { SurfaceResourceID(machine: machine, kind: .terminal, key: $0) }
                guard wanted.allSatisfy({ catalog.resources[$0] != nil }) else { continue }
                let present = Set(target.projections.map(\.resource))
                for resourceID in wanted where !present.contains(resourceID) {
                    let view = try catalog.remoteView(for: resourceID, workspaceID: target.remoteID)
                    _ = try await catalog.project(resourceID, into: .workspace(id: id, placement: .tab),
                        focus: false, reuseExisting: true, reuseInWorkspace: id, remoteView: view)
                }
                guard !Task.isCancelled, suspended.isEmpty, snapshots[target.remoteID] == snapshot,
                      writers[target.remoteID] == nil, pending[target.remoteID] == nil else { continue }
                for projection in target.projections where !wanted.contains(projection.resource) {
                    native.performRemoteTmuxMirrorMutation {
                        SurfacePaneFactory.closeExited(panelID: projection.panelID, in: id)
                        catalog.endProjections(panelID: projection.panelID, reason: .replaced)
                    }
                }
                guard let current = self.target(for: id) else { continue }
                let reverse = Dictionary(current.mapping.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
                let translated = try snapshot.layout.remappingSurfaceIDs(reverse)
                try native.applyDeviceWorkspaceLayout(translated)
                deliveries[id] = Delivery(revision: snapshot.revision, panels: Set(native.panels.keys), sourceIDs: Set(sourceIDs))
            } catch {
                guard !Task.isCancelled else { return }
                // A source delta can precede terminal metadata. The next
                // catalog/event update retries; no polling loop is started.
            }
        }
    }

    func waitForIdle() async {
        while reconcileTask != nil || !writers.isEmpty {
            let current = Array(writers.values)
            await reconcileTask?.value
            for task in current { await task.value }
        }
    }
}
