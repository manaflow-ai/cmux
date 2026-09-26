import CmuxCloud
import CmuxCore
import CmuxSurfaceCatalogModel
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
    @MainActor
    private final class CloseOperation {
        let surfaceID: String
        let workspaceID: UUID?
        let result: Task<Void, Error>
        private let continuation: AsyncThrowingStream<Void, Error>.Continuation
        private var resolved = false

        init(surfaceID: String, workspaceID: UUID?) {
            self.surfaceID = surfaceID
            self.workspaceID = workspaceID
            let pair = AsyncThrowingStream<Void, Error>.makeStream()
            continuation = pair.continuation
            result = Task { for try await _ in pair.stream {} }
        }

        func succeed() {
            guard !resolved else { return }
            resolved = true
            continuation.yield(())
            continuation.finish()
        }

        func fail(_ error: any Error) {
            guard !resolved else { return }
            resolved = true
            continuation.finish(throwing: error)
        }
    }

    /// A FIFO queue with an advancing head avoids shifting every remaining
    /// close when a workspace deletion contains many terminals.
    private struct CloseQueue {
        private var values: [CloseOperation] = []
        private var head = 0

        var isEmpty: Bool { head >= values.count }

        mutating func append(_ operation: CloseOperation) {
            values.append(operation)
        }

        mutating func popFirst() -> CloseOperation? {
            guard head < values.count else { return nil }
            let operation = values[head]
            head += 1
            if head == values.count {
                values.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 32, head * 2 >= values.count {
                values.removeFirst(head)
                head = 0
            }
            return operation
        }

        mutating func removeAll() -> [CloseOperation] {
            let remaining = Array(values.dropFirst(head))
            values.removeAll(keepingCapacity: false)
            head = 0
            return remaining
        }
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
    private var pendingCloses: [String: CloseQueue] = [:]
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
        cancelPendingCloses()
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
            cancelPendingCloses()
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

    /// Only an explicit close in a synchronized whole-workspace mirror edits its owner.
    func projectionDidEnd(_ projection: SurfaceProjection, reason: SurfaceProjectionEndReason) {
        guard reason == .paneClosed, projection.resource.machine == machine,
              !projection.isLocalWorkspaceView, let native = workspace(projection.workspaceID), let catalog,
              let remoteID = projection.remoteWorkspaceID,
              let delivery = deliveries[projection.workspaceID],
              delivery.panels.contains(projection.panelID), delivery.sourceIDs.contains(projection.resource.key) else { return }
        // A once-synchronized workspace can acquire local or unrelated panes.
        // Its old delivery must not turn closing a preview into a source deletion.
        // A pending or failed creation for the same workspace is not such a pane.
        let remaining = catalog.projections.filter { $0.workspaceID == projection.workspaceID }
        let reserved = native.cloudPendingCreations.values.filter {
            $0.machine == machine && $0.remoteWorkspaceID == remoteID
        }.map(\.panelID)
        guard remaining.allSatisfy({ $0.resource.machine == machine && $0.remoteWorkspaceID == remoteID }),
              Set(remaining.map(\.panelID)) == Set(native.panels.keys).subtracting([projection.panelID]).subtracting(reserved) else { return }
        let operation = enqueueClose(surfaceID: projection.resource.key, remoteID: remoteID, workspaceID: projection.workspaceID)
        Task { @MainActor [weak self] in
            do {
                try await operation.result.value
            } catch let error where !(error is CancellationError) {
                guard let self else { return }
                self.workspace(projection.workspaceID)?.presentDeviceLayoutFailure(error, machine: self.machine)
            } catch {
                // Disconnect and explicit teardown cancel an outstanding close.
            }
        }
    }

    /// Sidebar terminal deletion and mirrored-pane close use the same ordered host request.
    func closeTerminal(surfaceID: String, remoteWorkspaceID: String) async throws {
        try Task.checkCancellation()
        let operation = enqueueClose(surfaceID: surfaceID, remoteID: remoteWorkspaceID, workspaceID: nil)
        try await operation.result.value
    }

    private func enqueueClose(surfaceID: String, remoteID: String, workspaceID: UUID?) -> CloseOperation {
        let operation = CloseOperation(surfaceID: surfaceID, workspaceID: workspaceID)
        guard !stopped, isConnected() else {
            operation.fail(DeviceLinkError.notConnected)
            return operation
        }
        // An unsent arrangement containing a deleted terminal is no longer an
        // applicable intent. In-flight edits finish before the close request.
        pending[remoteID] = nil
        pendingCloses[remoteID, default: CloseQueue()].append(operation)
        startWriter(for: remoteID)
        return operation
    }

    private func cancelPendingCloses() {
        var abandoned: [CloseOperation] = []
        for remoteID in pendingCloses.keys {
            abandoned.append(contentsOf: pendingCloses[remoteID]?.removeAll() ?? [])
        }
        pendingCloses.removeAll()
        for close in abandoned { close.fail(CancellationError()) }
    }

    private func dequeueClose(for remoteID: String) -> CloseOperation? {
        // Mutate through the dictionary accessor so the backing array stays
        // uniquely owned; copying the queue before removal would force COW.
        guard let operation = pendingCloses[remoteID]?.popFirst() else { return nil }
        if pendingCloses[remoteID]?.isEmpty == true { pendingCloses[remoteID] = nil }
        return operation
    }

    private func performClose(_ close: CloseOperation, remoteID: String) async {
        do {
            try Task.checkCancellation()
            // Fresh workspace membership prevents closing a terminal that was
            // concurrently moved elsewhere; the RPC also scopes the target.
            try await fetch(remoteID)
            let present = try snapshots[remoteID]?.layout.validatedSurfaceIDs().contains {
                $0.caseInsensitiveCompare(close.surfaceID) == .orderedSame
            } == true
            if !present, close.workspaceID == nil {
                throw DeviceLinkError.malformedResponse("mobile.terminal.close")
            }
            if present {
                let data = try await request("mobile.terminal.close", ["workspace_id": remoteID, "surface_id": close.surfaceID])
                guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      reply["closed"] as? Bool == true,
                      (reply["workspace_id"] as? String)?.caseInsensitiveCompare(remoteID) == .orderedSame,
                      (reply["surface_id"] as? String)?.caseInsensitiveCompare(close.surfaceID) == .orderedSame else {
                    throw DeviceLinkError.malformedResponse("mobile.terminal.close")
                }
                try Task.checkCancellation()
                try await fetch(remoteID)
            }
            await refresh()
            if let id = close.workspaceID { deliveries[id] = nil }
            close.succeed()
        } catch {
            if !Task.isCancelled, !stopped {
                try? await fetch(remoteID)
                await refresh()
                // Restore the source layout after a refused/failed close, instead
                // of treating its missing local pane as a permanent detach.
                if let id = close.workspaceID { deliveries[id] = nil }
            }
            close.fail(error)
        }
    }

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
        // A reserved pane has no terminal on the owner yet, so it stays local.
        guard !isExternal, !stopped, let target = target(for: workspaceID),
              let native = capturedLayout ?? workspace(workspaceID)?.deviceWorkspaceLayoutSnapshot(),
              let mapped = try? native.removingSurfaceIDs(Set(target.reserved.map(\.uuidString)))?
                  .remappingSurfaceIDs(target.mapping),
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
                if self.pending[remoteID] != nil || self.pendingCloses[remoteID]?.isEmpty == false,
                   self.isConnected(), !self.stopped {
                    self.startWriter(for: remoteID)
                }
                self.scheduleReconcile()
            }
            while !Task.isCancelled {
                if let close = self.dequeueClose(for: remoteID) {
                    await self.performClose(close, remoteID: remoteID)
                    continue
                }
                guard let intent = self.pending.removeValue(forKey: remoteID) else { break }
                do {
                    try Task.checkCancellation()
                    if self.sequences[remoteID] == nil || self.fetchRequested.remove(remoteID) != nil {
                        try await self.fetch(remoteID)
                    }
                    guard let accepted = self.snapshots[remoteID], !accepted.revision.isEmpty else {
                        throw DeviceLinkError.malformedResponse("device.workspace.layout")
                    }
                    guard Set(try intent.layout.validatedSurfaceIDs()) == Set(try accepted.layout.validatedSurfaceIDs()) else {
                        self.deliveries[intent.workspaceID] = nil
                        continue
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

    private func target(for id: UUID) -> (
        remoteID: String, mapping: [String: String], projections: [SurfaceProjection], reserved: Set<UUID>
    )? {
        guard let catalog, let native = workspace(id) else { return nil }
        let projections = catalog.projections.filter { $0.workspaceID == id && $0.resource.machine == machine }
        guard !projections.isEmpty else { return nil }
        let projectedPanelIDs = Set(projections.map(\.panelID))
        let pending = native.cloudPendingCreations.values.filter {
            $0.machine == machine && $0.remoteWorkspaceID != nil
        }
        let pendingPanelIDs = Set(pending.map(\.panelID))
        let nativePanelIDs = Set(native.panels.keys)
        guard projectedPanelIDs.isSubset(of: nativePanelIDs),
              nativePanelIDs.subtracting(projectedPanelIDs).isSubset(of: pendingPanelIDs) else { return nil }
        let remoteIDs = Set(projections.compactMap(\.remoteWorkspaceID))
            .union(pending.compactMap(\.remoteWorkspaceID))
        guard remoteIDs.count == 1, let remoteID = remoteIDs.first,
              projections.allSatisfy({ $0.remoteWorkspaceID == remoteID }) else { return nil }
        let mapping = Dictionary(projections.map { ($0.panelID.uuidString, $0.resource.key) }, uniquingKeysWith: { first, _ in first })
        return (remoteID, mapping, Array(projections), nativePanelIDs.subtracting(projectedPanelIDs))
    }

    /// Establishes the exact terminal identity before its authoritative layout
    /// snapshot is accepted. This closes the reservation-to-resource race.
    func bindCreatedTerminal(requestID: UUID, remoteWorkspaceID: String, resource: SurfaceResource) -> Bool {
        let workspaceIDs = Set(catalog?.projections.filter { $0.resource.machine == machine }.map(\.workspaceID) ?? [])
        for workspaceID in workspaceIDs {
            if workspace(workspaceID)?.bindPendingDeviceTerminal(
                requestID: requestID, remoteWorkspaceID: remoteWorkspaceID, resource: resource
            ) == true { return true }
        }
        return false
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
                let locations = DeviceWorkspaceProjection(machine: machine, isLive: true)
                    .layoutLocations(snapshot.layout)
                // Reserved panes keep their place beside the terminals already
                // arranged here, not beside one this pass projects at a fallback.
                let arranged = native.deviceWorkspaceLayoutSnapshot()
                var localPanesByRemotePane: [String: UUID] = [:]
                for (panelID, remoteSurfaceID) in target.mapping {
                    guard let location = locations[remoteSurfaceID],
                          let panelUUID = UUID(uuidString: panelID),
                          let pane = native.paneId(forPanelId: panelUUID) else { continue }
                    localPanesByRemotePane[location.paneID] = pane.id
                }
                for resourceID in wanted where !present.contains(resourceID) {
                    let view = try catalog.remoteView(for: resourceID, workspaceID: target.remoteID)
                    let location = locations[resourceID.key]
                    // Only the reservation bound to this terminal lends its pane,
                    // and that same reservation is the one adopted.
                    let reservation = native.pendingCloudTerminalReservation(
                        for: resourceID, remoteWorkspaceID: target.remoteID, remoteTabID: view?.tabID
                    )
                    let pane = location.flatMap { localPanesByRemotePane[$0.paneID] }
                        ?? reservation.flatMap { native.paneId(forPanelId: $0.panelID)?.id }
                    let destination: SurfaceDestination = pane.map {
                        .tab(workspaceID: id, paneID: $0.uuidString, index: location?.tabIndex)
                    } ?? .workspace(id: id, placement: .tab)
                    _ = try await catalog.project(resourceID, into: destination,
                        focus: false, reuseExisting: true, reuseInWorkspace: id,
                        remoteView: view, adopting: reservation)
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
                var translated = try snapshot.layout.remappingSurfaceIDs(reverse)
                if !current.reserved.isEmpty, let arranged {
                    translated = translated.grafting(Set(current.reserved.map(\.uuidString)), from: arranged)
                }
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

extension DeviceWorkspaceLayoutNode {
    /// The panel IDs in pane and tab order, without validation.
    fileprivate var orderedSurfaceIDs: [String] {
        switch self {
        case .pane(_, let surfaces, _): return surfaces
        case .split(_, _, let first, let second): return first.orderedSurfaceIDs + second.orderedSurfaceIDs
        }
    }

    /// Drops panels the owning Mac does not know. An emptied pane yields its
    /// space to its sibling.
    fileprivate func removingSurfaceIDs(_ removed: Set<String>) -> DeviceWorkspaceLayoutNode? {
        guard !removed.isEmpty else { return self }
        switch self {
        case .pane(let id, let surfaces, let selected):
            let kept = surfaces.filter { !removed.contains($0) }
            guard !kept.isEmpty else { return nil }
            return .pane(id: id, surfaceIDs: kept, selectedSurfaceID: selected.flatMap { kept.contains($0) ? $0 : nil })
        case .split(let direction, let ratio, let first, let second):
            switch (first.removingSurfaceIDs(removed), second.removingSurfaceIDs(removed)) {
            case (let first?, let second?): return .split(direction: direction, ratio: ratio, first: first, second: second)
            case (let only?, nil), (nil, let only?): return only
            case (nil, nil): return nil
            }
        }
    }

    /// Restores `kept` panels, which the owning Mac does not know, where
    /// `local` shows them: a tab beside its neighbor in the same pane, and a
    /// split beside the terminals it divided.
    fileprivate func grafting(_ kept: Set<String>, from local: DeviceWorkspaceLayoutNode) -> DeviceWorkspaceLayoutNode {
        var result = self
        local.graft(kept, into: &result)
        // A panel whose neighbors all left, or that `local` predates, still
        // needs a place: local order where known, then the rest.
        let present = Set(result.orderedSurfaceIDs)
        let known = local.orderedSurfaceIDs.filter { kept.contains($0) && !present.contains($0) }
        let stranded = known + kept.subtracting(present).subtracting(known).sorted()
        if let anchor = result.orderedSurfaceIDs.last {
            for surface in stranded.reversed() {
                result = result.inserting(surface, beside: anchor, after: true)
            }
        }
        return result
    }

    private func graft(_ kept: Set<String>, into result: inout DeviceWorkspaceLayoutNode) {
        switch self {
        case .pane(_, let surfaces, _):
            var present = Set(result.orderedSurfaceIDs)
            for (index, surface) in surfaces.enumerated() where kept.contains(surface) && !present.contains(surface) {
                if let anchor = surfaces[..<index].last(where: { present.contains($0) }) {
                    result = result.inserting(surface, beside: anchor, after: true)
                } else if let anchor = surfaces[(index + 1)...].first(where: { present.contains($0) }) {
                    result = result.inserting(surface, beside: anchor, after: false)
                } else {
                    continue
                }
                present.insert(surface)
            }
        case .split(let direction, let ratio, let first, let second):
            let firstIsKept = !first.orderedSurfaceIDs.isEmpty && first.orderedSurfaceIDs.allSatisfy(kept.contains)
            let secondIsKept = !second.orderedSurfaceIDs.isEmpty && second.orderedSurfaceIDs.allSatisfy(kept.contains)
            guard firstIsKept != secondIsKept else {
                first.graft(kept, into: &result)
                second.graft(kept, into: &result)
                return
            }
            let (branch, sibling) = firstIsKept ? (first, second) : (second, first)
            let present = Set(result.orderedSurfaceIDs)
            let anchors = Set(sibling.orderedSurfaceIDs.filter { present.contains($0) })
            if !anchors.isEmpty {
                result = result.wrapping(anchors, with: branch, direction: direction, ratio: ratio, branchFirst: firstIsKept)
            }
            sibling.graft(kept, into: &result)
        }
    }

    private func inserting(_ surface: String, beside anchor: String, after: Bool) -> DeviceWorkspaceLayoutNode {
        switch self {
        case .pane(let id, var surfaces, let selected):
            guard let index = surfaces.firstIndex(of: anchor) else { return self }
            surfaces.insert(surface, at: after ? index + 1 : index)
            return .pane(id: id, surfaceIDs: surfaces, selectedSurfaceID: selected)
        case .split(let direction, let ratio, let first, let second):
            return .split(direction: direction, ratio: ratio,
                first: first.inserting(surface, beside: anchor, after: after),
                second: second.inserting(surface, beside: anchor, after: after))
        }
    }

    /// Splits the smallest subtree holding every anchor, restoring `branch` on
    /// the side `local` placed it.
    private func wrapping(_ anchors: Set<String>, with branch: DeviceWorkspaceLayoutNode,
                          direction: Direction, ratio: Double, branchFirst: Bool) -> DeviceWorkspaceLayoutNode {
        if case .split(let ownDirection, let ownRatio, let first, let second) = self {
            if anchors.isSubset(of: first.orderedSurfaceIDs) {
                return .split(direction: ownDirection, ratio: ownRatio,
                    first: first.wrapping(anchors, with: branch, direction: direction, ratio: ratio, branchFirst: branchFirst),
                    second: second)
            }
            if anchors.isSubset(of: second.orderedSurfaceIDs) {
                return .split(direction: ownDirection, ratio: ownRatio, first: first,
                    second: second.wrapping(anchors, with: branch, direction: direction, ratio: ratio, branchFirst: branchFirst))
            }
        }
        return branchFirst
            ? .split(direction: direction, ratio: ratio, first: branch, second: self)
            : .split(direction: direction, ratio: ratio, first: self, second: branch)
    }
}
