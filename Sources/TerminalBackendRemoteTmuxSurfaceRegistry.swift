import CmuxTerminalBackend
import Foundation

enum TerminalBackendRemoteTmuxRegistryError: Error, Equatable, Sendable {
    case invalidProducerTopology(UUID)
    case claimIdentityMismatch(UUID)
    case missingProducerSource(UUID)
    case sourceUpdateIdentityMismatch(UUID)
}

/// Private reconnect data paired with canonical, non-secret surface identities.
/// The source is held only for the duration of this authenticated frontend
/// connection and is never copied into Swift restoration state.
struct TerminalBackendRemoteTmuxProducerProjection: Equatable, Sendable {
    struct Surface: Equatable, Sendable {
        let workspaceID: UUID
        let surfaceID: SurfaceID
        let provenance: CanonicalExternalTerminalProvenance
    }

    let producerID: UUID
    let source: BackendRemoteTmuxProducerSource
    let workspaceID: UUID
    let tmuxSessionID: UInt64
    let surfaces: [Surface]
}

/// Process-local binding between canonical parser-only terminals and a live
/// remote tmux control connection. Canonical topology owns every stable ID;
/// this registry only installs ephemeral I/O endpoints and private source leases.
@MainActor
final class TerminalBackendRemoteTmuxSurfaceRegistry {
    enum PresentationRole: Equatable {
        case workspaceTab
        case nestedPane

        init(_ role: CanonicalExternalTerminalProvenance.PresentationRole) {
            switch role {
            case .workspaceTab: self = .workspaceTab
            case .nestedPane: self = .nestedPane
            }
        }
    }

    struct Registration: Equatable {
        let surfaceID: UUID
        let isNew: Bool
        let isProjected: Bool
    }

    private struct Key: Hashable {
        let producerID: UUID
        let tmuxPaneID: UInt64
    }

    private final class Record {
        let key: Key
        let surfaceID: SurfaceID
        var workspaceID: UUID
        var provenance: CanonicalExternalTerminalProvenance
        let bridge: TerminalBackendRemoteTmuxSurfaceBridge
        var projected = false
        var retired = false
        var endpointsReady = false
        var projectionCallback: (@MainActor () -> Void)?

        init(
            key: Key,
            surfaceID: SurfaceID,
            workspaceID: UUID,
            provenance: CanonicalExternalTerminalProvenance,
            bridge: TerminalBackendRemoteTmuxSurfaceBridge
        ) {
            self.key = key
            self.surfaceID = surfaceID
            self.workspaceID = workspaceID
            self.provenance = provenance
            self.bridge = bridge
        }
    }

    private final class Producer {
        let producerID: UUID
        var workspaceID: UUID
        var tmuxSessionID: UInt64
        var authority: BackendAuthority?
        var ownerGeneration: UInt64?
        var source: BackendRemoteTmuxProducerSource?
        var claimRequestID: UUID?
        var restorationRequested = false

        init(producerID: UUID, workspaceID: UUID, tmuxSessionID: UInt64) {
            self.producerID = producerID
            self.workspaceID = workspaceID
            self.tmuxSessionID = tmuxSessionID
        }
    }

    private struct ClaimPreparation: Sendable {
        let producerID: UUID
        let requestID: UUID
        let localSource: BackendRemoteTmuxProducerSource?
    }

    private let service: any TerminalBackendExternalTerminalServing
    private let producerSourceService: any TerminalBackendRemoteTmuxProducerSourceServing
    private let recoveryHandler: TerminalBackendRemoteTmuxSurfaceBridge.RecoveryHandler
    private var recordsByKey: [Key: Record] = [:]
    private var recordsBySurfaceID: [SurfaceID: Record] = [:]
    private var producers: [UUID: Producer] = [:]
    private var producerIDByWorkspace: [UUID: UUID] = [:]
    private var pendingSourceUpdates: [UUID: BackendRemoteTmuxProducerSource] = [:]
    private var sourceUpdateTasks: [UUID: Task<Void, Never>] = [:]

    init(
        service: any TerminalBackendExternalTerminalServing,
        producerSourceService: any TerminalBackendRemoteTmuxProducerSourceServing,
        recoveryHandler: @escaping TerminalBackendRemoteTmuxSurfaceBridge.RecoveryHandler = {}
    ) {
        self.service = service
        self.producerSourceService = producerSourceService
        self.recoveryHandler = recoveryHandler
    }

    deinit {
        for task in sourceUpdateTasks.values { task.cancel() }
    }

    /// Adopts daemon identities before AppKit plans the projection. This is the
    /// restart boundary: nested roles are known before panel allocation and a
    /// later live connection reuses these exact producer and surface IDs.
    func claimBeforeProjection(
        authority: BackendAuthority,
        plan: TerminalBackendTopologyProjectionPlan
    ) async throws {
        let surfaces = plan.workspaces.flatMap { workspace in
            workspace.screens.flatMap { screen in
                screen.panes.flatMap { pane in
                    pane.tabs.compactMap { surface -> TerminalBackendRemoteTmuxProducerProjection.Surface? in
                        guard let provenance = surface.externalTerminalProvenance,
                              provenance.producerKind == .remoteTmux else { return nil }
                        return .init(
                            workspaceID: workspace.canonical.uuid.rawValue,
                            surfaceID: surface.uuid,
                            provenance: provenance
                        )
                    }
                }
            }
        }
        let grouped = Dictionary(grouping: surfaces, by: { $0.provenance.producerID })
        for (producerID, producerSurfaces) in grouped {
            try validateProducerTopology(producerID: producerID, surfaces: producerSurfaces)
            guard let first = producerSurfaces.first else { continue }
            let producer = producers[producerID] ?? Producer(
                producerID: producerID,
                workspaceID: first.workspaceID,
                tmuxSessionID: first.provenance.tmuxSessionID
            )
            producer.workspaceID = first.workspaceID
            producer.tmuxSessionID = first.provenance.tmuxSessionID
            producers[producerID] = producer
            if let existing = producerIDByWorkspace[first.workspaceID], existing != producerID {
                throw TerminalBackendRemoteTmuxRegistryError.invalidProducerTopology(producerID)
            }
            producerIDByWorkspace[first.workspaceID] = producerID
            for surface in producerSurfaces {
                try adoptCanonicalSurface(surface)
            }
        }

        var preparations: [ClaimPreparation] = []
        for producerID in grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let producer = producers[producerID], producer.authority != authority else {
                continue
            }
            let requestID = producer.claimRequestID ?? UUID()
            producer.claimRequestID = requestID
            preparations.append(.init(
                producerID: producerID,
                requestID: requestID,
                localSource: producer.source
            ))
        }

        let sourceService = producerSourceService
        for start in stride(from: 0, to: preparations.count, by: 16) {
            let batch = Array(preparations[start..<min(start + 16, preparations.count)])
            let receipts = try await withThrowingTaskGroup(
                of: (ClaimPreparation, BackendRemoteTmuxProducerSourceClaimReceipt).self,
                returning: [(ClaimPreparation, BackendRemoteTmuxProducerSourceClaimReceipt)].self
            ) { group in
                for preparation in batch {
                    group.addTask {
                        let receipt = try await sourceService.claimRemoteTmuxProducerSource(
                            producerID: preparation.producerID,
                            requestID: preparation.requestID,
                            source: preparation.localSource
                        )
                        return (preparation, receipt)
                    }
                }
                var values: [(ClaimPreparation, BackendRemoteTmuxProducerSourceClaimReceipt)] = []
                for try await value in group { values.append(value) }
                return values
            }
            for (preparation, receipt) in receipts {
                guard receipt.authority == authority,
                      receipt.producerID == preparation.producerID,
                      receipt.requestID == preparation.requestID,
                      receipt.ownerGeneration > 0 else {
                    throw TerminalBackendRemoteTmuxRegistryError
                        .claimIdentityMismatch(preparation.producerID)
                }
                guard let source = receipt.source ?? preparation.localSource else {
                    throw TerminalBackendRemoteTmuxRegistryError
                        .missingProducerSource(preparation.producerID)
                }
                guard let producer = producers[preparation.producerID] else { continue }
                producer.authority = authority
                producer.ownerGeneration = receipt.ownerGeneration
                producer.source = source
                producer.claimRequestID = nil
                for record in recordsByKey.values
                where record.key.producerID == preparation.producerID {
                    record.bridge.backendConnectionDidReconnect()
                }
            }
        }
    }

    func register(
        workspaceID: UUID,
        provenance: CanonicalExternalTerminalProvenance,
        producerSource: BackendRemoteTmuxProducerSource? = nil,
        sendKeys: @escaping TerminalBackendRemoteTmuxSurfaceBridge.SendKeys,
        requestSeed: @escaping TerminalBackendRemoteTmuxSurfaceBridge.RequestSeed,
        onProjected: (@MainActor () -> Void)? = nil
    ) -> Registration? {
        let key = Key(producerID: provenance.producerID, tmuxPaneID: provenance.tmuxPaneID)
        let producer = producers[provenance.producerID] ?? Producer(
            producerID: provenance.producerID,
            workspaceID: workspaceID,
            tmuxSessionID: provenance.tmuxSessionID
        )
        guard producer.workspaceID == workspaceID,
              producer.tmuxSessionID == provenance.tmuxSessionID,
              producerIDByWorkspace[workspaceID] == nil
                || producerIDByWorkspace[workspaceID] == provenance.producerID else { return nil }
        if let producerSource { producer.source = producerSource }
        producer.restorationRequested = true
        producers[provenance.producerID] = producer
        producerIDByWorkspace[workspaceID] = provenance.producerID

        if let record = recordsByKey[key] {
            guard record.surfaceID == recordsBySurfaceID[record.surfaceID]?.surfaceID,
                  record.workspaceID == workspaceID,
                  record.provenance.tmuxWindowID == provenance.tmuxWindowID,
                  record.provenance.presentationRole == provenance.presentationRole else {
                return nil
            }
            record.retired = false
            record.endpointsReady = true
            record.projectionCallback = onProjected
            record.bridge.updateEndpoints(
                sendKeys: sendKeys,
                requestSeed: requestSeed,
                requestSeedIfNeeded: record.projected
            )
            return Registration(
                surfaceID: record.surfaceID.rawValue,
                isNew: false,
                isProjected: record.projected
            )
        }

        let surfaceID = SurfaceID(rawValue: UUID())
        let bridge = makeBridge(
            surfaceID: surfaceID,
            sendKeys: sendKeys,
            requestSeed: requestSeed
        )
        let record = Record(
            key: key,
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            provenance: provenance,
            bridge: bridge
        )
        record.endpointsReady = true
        record.projectionCallback = onProjected
        recordsByKey[key] = record
        recordsBySurfaceID[surfaceID] = record
        return Registration(surfaceID: surfaceID.rawValue, isNew: true, isProjected: false)
    }

    func markProjected(surfaceID: UUID) {
        guard let record = recordsBySurfaceID[SurfaceID(rawValue: surfaceID)],
              !record.retired else { return }
        record.projected = true
        if record.endpointsReady { record.bridge.activate() }
        record.projectionCallback?()
    }

    func materializationFailed(surfaceID: UUID) {
        let typedID = SurfaceID(rawValue: surfaceID)
        guard let record = recordsBySurfaceID[typedID],
              !record.projected else { return }
        remove(record)
        record.projectionCallback?()
    }

    func projectionDidInstall(
        plan: TerminalBackendTopologyProjectionPlan,
        projector: any TerminalBackendTopologyProjecting
    ) {
        let activeSurfaceIDs = Set(plan.surfaceWorkspaceIDs.keys)
        for record in recordsBySurfaceID.values {
            guard activeSurfaceIDs.contains(record.surfaceID) else { continue }
            record.projected = true
            record.retired = false
            if record.endpointsReady { record.bridge.activate() }
        }

        let activeProducerIDs = Set(recordsBySurfaceID.values.compactMap {
            activeSurfaceIDs.contains($0.surfaceID) ? $0.key.producerID : nil
        })
        for producerID in activeProducerIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let producer = producers[producerID],
                  !producer.restorationRequested,
                  let source = producer.source else { continue }
            let surfaces = recordsBySurfaceID.values
                .filter { $0.key.producerID == producerID && activeSurfaceIDs.contains($0.surfaceID) }
                .map {
                    TerminalBackendRemoteTmuxProducerProjection.Surface(
                        workspaceID: $0.workspaceID,
                        surfaceID: $0.surfaceID,
                        provenance: $0.provenance
                    )
                }
                .sorted { $0.surfaceID.rawValue.uuidString < $1.surfaceID.rawValue.uuidString }
            let projection = TerminalBackendRemoteTmuxProducerProjection(
                producerID: producerID,
                source: source,
                workspaceID: producer.workspaceID,
                tmuxSessionID: producer.tmuxSessionID,
                surfaces: surfaces
            )
            if projector.restoreRemoteTmuxProducer(projection) {
                producer.restorationRequested = true
            }
        }

        let stale = recordsBySurfaceID.values.filter {
            !activeSurfaceIDs.contains($0.surfaceID) && $0.retired
        }
        for record in stale { remove(record) }
    }

    func restorationFailed(producerID: UUID) {
        producers[producerID]?.restorationRequested = false
    }

    func updateProducerSource(
        producerID: UUID,
        source: BackendRemoteTmuxProducerSource
    ) {
        guard producers[producerID] != nil else { return }
        pendingSourceUpdates[producerID] = source
        guard sourceUpdateTasks[producerID] == nil else { return }
        sourceUpdateTasks[producerID] = Task { [weak self] in
            await self?.runSourceUpdateLoop(producerID: producerID)
        }
    }

    func receiveSeed(
        _ seed: RemoteTmuxPaneSeed,
        workspaceID: UUID,
        tmuxPaneID: Int,
        columns: Int,
        rows: Int,
        noReflow: Bool
    ) {
        guard let record = record(workspaceID: workspaceID, tmuxPaneID: tmuxPaneID),
              let columns = UInt16(exactly: max(columns, 1)),
              let rows = UInt16(exactly: max(rows, 1)) else { return }
        record.bridge.receiveSeed(seed, columns: columns, rows: rows, noReflow: noReflow)
    }

    func receiveOutput(_ data: Data, workspaceID: UUID, tmuxPaneID: Int) {
        record(workspaceID: workspaceID, tmuxPaneID: tmuxPaneID)?.bridge.receiveOutput(data)
    }

    func seedFailed(workspaceID: UUID, tmuxPaneID: Int) {
        record(workspaceID: workspaceID, tmuxPaneID: tmuxPaneID)?.bridge.seedFailed()
    }

    func updateNoReflow(_ noReflow: Bool, workspaceID: UUID, tmuxPaneID: Int) {
        record(workspaceID: workspaceID, tmuxPaneID: tmuxPaneID)?
            .bridge.updateNoReflow(noReflow)
    }

    func remoteConnectionDidDisconnect(workspaceID: UUID) {
        for record in recordsByKey.values where record.workspaceID == workspaceID {
            record.bridge.remoteConnectionDidDisconnect()
        }
    }

    func backendDidDisconnect() {
        for task in sourceUpdateTasks.values { task.cancel() }
        sourceUpdateTasks.removeAll(keepingCapacity: false)
        pendingSourceUpdates.removeAll(keepingCapacity: false)
        for producer in producers.values {
            producer.authority = nil
            producer.ownerGeneration = nil
            producer.claimRequestID = nil
            producer.restorationRequested = producerHasLiveEndpoints(producer.producerID)
        }
        for record in recordsByKey.values { record.bridge.backendConnectionDidDisconnect() }
    }

    func retire(workspaceID: UUID, tmuxPaneID: Int) {
        guard let record = record(workspaceID: workspaceID, tmuxPaneID: tmuxPaneID) else {
            return
        }
        record.retired = true
        record.bridge.retire()
    }

    func retireIfNested(workspaceID: UUID, tmuxPaneID: Int) {
        guard let record = record(workspaceID: workspaceID, tmuxPaneID: tmuxPaneID),
              record.provenance.presentationRole == .nestedPane else { return }
        record.retired = true
        record.bridge.retire()
    }

    func runtimeMutationRouter(surfaceID: UUID) ->
        (any TerminalBackendExternalRuntimeMutationRouting)?
    {
        recordsBySurfaceID[SurfaceID(rawValue: surfaceID)]?.bridge
    }

    func shouldProjectCanonicalSurface(_ surfaceID: SurfaceID) -> Bool {
        recordsBySurfaceID[surfaceID]?.provenance.presentationRole != .nestedPane
    }

    func projectedSurfaceID(workspaceID: UUID, tmuxPaneID: Int) -> UUID? {
        guard let record = record(workspaceID: workspaceID, tmuxPaneID: tmuxPaneID),
              record.projected,
              !record.retired else { return nil }
        return record.surfaceID.rawValue
    }

    func surfaceID(workspaceID: UUID, tmuxPaneID: Int) -> UUID? {
        record(workspaceID: workspaceID, tmuxPaneID: tmuxPaneID)?.surfaceID.rawValue
    }

    func requiresNestedPresentation(workspaceID: UUID, tmuxWindowID: Int) -> Bool {
        guard let windowID = UInt64(exactly: tmuxWindowID) else { return false }
        return recordsByKey.values.contains {
            $0.workspaceID == workspaceID
                && !$0.retired
                && $0.provenance.tmuxWindowID == windowID
                && $0.provenance.presentationRole == .nestedPane
        }
    }

    func canonicalProjectionDidInstall(surfaceIDs: Set<SurfaceID>) {
        let removed = recordsBySurfaceID.values.filter {
            $0.retired && !surfaceIDs.contains($0.surfaceID)
        }
        for record in removed { remove(record) }
    }

    func bridgeForTesting(surfaceID: UUID) -> TerminalBackendRemoteTmuxSurfaceBridge? {
        recordsBySurfaceID[SurfaceID(rawValue: surfaceID)]?.bridge
    }

    private func adoptCanonicalSurface(
        _ surface: TerminalBackendRemoteTmuxProducerProjection.Surface
    ) throws {
        let provenance = surface.provenance
        let key = Key(producerID: provenance.producerID, tmuxPaneID: provenance.tmuxPaneID)
        if let byKey = recordsByKey[key], byKey.surfaceID != surface.surfaceID {
            throw TerminalBackendRemoteTmuxRegistryError
                .invalidProducerTopology(provenance.producerID)
        }
        if let bySurface = recordsBySurfaceID[surface.surfaceID], bySurface.key != key {
            throw TerminalBackendRemoteTmuxRegistryError
                .invalidProducerTopology(provenance.producerID)
        }
        if let record = recordsByKey[key] {
            guard record.workspaceID == surface.workspaceID,
                  record.provenance == provenance else {
                throw TerminalBackendRemoteTmuxRegistryError
                    .invalidProducerTopology(provenance.producerID)
            }
            return
        }
        let bridge = makeBridge(
            surfaceID: surface.surfaceID,
            sendKeys: { _ in false },
            requestSeed: {}
        )
        let record = Record(
            key: key,
            surfaceID: surface.surfaceID,
            workspaceID: surface.workspaceID,
            provenance: provenance,
            bridge: bridge
        )
        recordsByKey[key] = record
        recordsBySurfaceID[surface.surfaceID] = record
    }

    private func validateProducerTopology(
        producerID: UUID,
        surfaces: [TerminalBackendRemoteTmuxProducerProjection.Surface]
    ) throws {
        guard let first = surfaces.first,
              surfaces.allSatisfy({
                  $0.workspaceID == first.workspaceID
                      && $0.provenance.producerID == producerID
                      && $0.provenance.tmuxSessionID == first.provenance.tmuxSessionID
              }),
              Set(surfaces.map { $0.provenance.tmuxPaneID }).count == surfaces.count else {
            throw TerminalBackendRemoteTmuxRegistryError.invalidProducerTopology(producerID)
        }
        let workspaceWindows = Dictionary(
            grouping: surfaces.filter { $0.provenance.presentationRole == .workspaceTab },
            by: { $0.provenance.tmuxWindowID }
        )
        let allWindows = Set(surfaces.map { $0.provenance.tmuxWindowID })
        guard Set(workspaceWindows.keys) == allWindows,
              workspaceWindows.values.allSatisfy({ $0.count == 1 }) else {
            throw TerminalBackendRemoteTmuxRegistryError.invalidProducerTopology(producerID)
        }
    }

    private func makeBridge(
        surfaceID: SurfaceID,
        sendKeys: @escaping TerminalBackendRemoteTmuxSurfaceBridge.SendKeys,
        requestSeed: @escaping TerminalBackendRemoteTmuxSurfaceBridge.RequestSeed
    ) -> TerminalBackendRemoteTmuxSurfaceBridge {
        TerminalBackendRemoteTmuxSurfaceBridge(
            surfaceID: surfaceID,
            service: service,
            sendKeys: sendKeys,
            requestSeed: requestSeed,
            recoveryHandler: recoveryHandler
        )
    }

    private func record(workspaceID: UUID, tmuxPaneID: Int) -> Record? {
        guard let paneID = UInt64(exactly: tmuxPaneID),
              let producerID = producerIDByWorkspace[workspaceID] else { return nil }
        return recordsByKey[Key(producerID: producerID, tmuxPaneID: paneID)]
    }

    private func producerHasLiveEndpoints(_ producerID: UUID) -> Bool {
        recordsByKey.values.contains {
            $0.key.producerID == producerID && $0.endpointsReady && !$0.retired
        }
    }

    private func remove(_ record: Record) {
        recordsBySurfaceID.removeValue(forKey: record.surfaceID)
        recordsByKey.removeValue(forKey: record.key)
        record.bridge.retire()
        if !recordsByKey.keys.contains(where: { $0.producerID == record.key.producerID }) {
            sourceUpdateTasks.removeValue(forKey: record.key.producerID)?.cancel()
            pendingSourceUpdates.removeValue(forKey: record.key.producerID)
            if let producer = producers.removeValue(forKey: record.key.producerID),
               producerIDByWorkspace[producer.workspaceID] == record.key.producerID {
                producerIDByWorkspace.removeValue(forKey: producer.workspaceID)
            }
        }
    }

    private func runSourceUpdateLoop(producerID: UUID) async {
        defer { sourceUpdateTasks.removeValue(forKey: producerID) }
        while !Task.isCancelled {
            guard let source = pendingSourceUpdates.removeValue(forKey: producerID),
                  let producer = producers[producerID],
                  let authority = producer.authority,
                  let ownerGeneration = producer.ownerGeneration else { return }
            let requestID = UUID()
            do {
                let receipt = try await producerSourceService.updateRemoteTmuxProducerSource(
                    producerID: producerID,
                    ownerGeneration: ownerGeneration,
                    requestID: requestID,
                    source: source
                )
                guard receipt.authority == authority,
                      receipt.producerID == producerID,
                      receipt.ownerGeneration == ownerGeneration,
                      receipt.requestID == requestID else {
                    throw TerminalBackendRemoteTmuxRegistryError
                        .sourceUpdateIdentityMismatch(producerID)
                }
                producer.source = source
                if pendingSourceUpdates[producerID] == nil { return }
            } catch is CancellationError {
                return
            } catch {
                producer.authority = nil
                producer.ownerGeneration = nil
                producer.restorationRequested = false
                Task { [recoveryHandler] in await recoveryHandler() }
                return
            }
        }
    }
}
