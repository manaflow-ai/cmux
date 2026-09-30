import CmuxCloud
import CmuxCloudTui
import CmuxSurfaceCatalogModel
import Foundation

/// Writes a native workspace arrangement to the machine, one revision-fenced step at a time.
@MainActor
extension CmuxTuiSurfaceProvider: SurfaceWorkspaceLayoutSyncing {
    /// Enough for a full rearrangement of a large workspace; a plan that has not
    /// converged by then is fighting a concurrent writer and yields to it.
    static let layoutSyncStepLimit = 64

    func syncWorkspaceLayout(_ desired: CloudLayoutSyncTree, remoteWorkspaceID: String) async throws -> CloudLayoutSyncStep {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        // Scratch terminals only hold a new pane open; none may outlive this sync.
        var scratch: [String: String] = [:]
        var mutated = false
        var outcome: CloudLayoutSyncStep = .notReady("the machine did not converge")
        do {
            steps: for _ in 0..<Self.layoutSyncStepLimit {
                try Task.checkCancellation()
                let data = try await link.run(arguments: CloudTuiRequests.snapshotArguments(socketPath: connected.socketPath))
                guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      CmuxTuiSnapshotParser.authoritativeGraphIsValid(snapshot) else {
                    throw ProviderError.invalidSnapshot(machineID)
                }
                let revision = CmuxTuiSnapshotParser.resourceRevision(from: snapshot)
                let step = CloudLayoutSyncPlanner(
                    snapshot: snapshot, workspaceID: remoteWorkspaceID, desired: desired, scratchTabIDs: Set(scratch.keys)
                ).step
                let request: CloudTuiRequest
                switch step {
                case .done, .notReady, .unsupported:
                    outcome = step
                    break steps
                case .moveTab(let tabID, let target):
                    request = CloudTuiRequests.moveTabArguments(
                        socketPath: connected.socketPath, tabID: tabID, target: target, expectedRevision: revision
                    )
                case .splitPane(let paneID):
                    request = CloudTuiRequests.paneCreate(
                        paneID: paneID, direction: SurfaceSplitDirection.right.rawValue, command: [],
                        revision: revision.flatMap { UInt64($0) },
                        key: "cmux-cloud-layout-\(UUID().uuidString.lowercased())", correlationKey: nil
                    )
                case .closeScratch(let tabID, let terminalID):
                    scratch[tabID] = nil
                    request = CloudTuiRequests.closeTerminalArguments(socketPath: connected.socketPath, terminalID: terminalID)
                case .applyLayout(let document):
                    guard let object = try JSONSerialization.jsonObject(with: document) as? [String: Any] else {
                        outcome = .unsupported("the layout document could not be decoded")
                        break steps
                    }
                    request = CloudTuiRequests.applyWorkspaceLayoutArguments(
                        workspaceID: remoteWorkspaceID, document: object, expectedRevision: revision
                    )
                }
                do {
                    let response = try await link.run(arguments: request)
                    mutated = true
                    if case .splitPane(let paneID) = step {
                        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                              let created = CmuxTuiSnapshotParser.createdTerminal(fromRunResult: object),
                              let tabID = created.tabID else {
                            throw ProviderError.terminalNotCreated(paneID)
                        }
                        scratch[tabID] = created.terminalID
                    }
                } catch let error where Self.isRevisionConflict(error) {
                    // Another writer moved first: replan from its result, never from ours.
                    continue
                }
            }
        } catch {
            await closeScratchTerminals(scratch.values, link: link, socketPath: connected.socketPath)
            if mutated { await refreshCurrentGraph(force: false) }
            throw error
        }
        await closeScratchTerminals(scratch.values, link: link, socketPath: connected.socketPath)
        // The projection coordinator may only resume from a graph that includes these
        // writes; an older published graph would re-apply the arrangement just replaced.
        if mutated { await refreshCurrentGraph(force: false) }
        return outcome
    }

    private func closeScratchTerminals(_ terminals: some Collection<String>, link: CloudMachineLink, socketPath: String) async {
        for terminalID in terminals {
            _ = try? await link.run(arguments: CloudTuiRequests.closeTerminalArguments(socketPath: socketPath, terminalID: terminalID))
        }
    }
}
