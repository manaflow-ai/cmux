import CmuxCloud
import CmuxCloudTui
import CmuxSurfaceCatalogModel
import CryptoKit
import Foundation

@MainActor
extension CmuxTuiSurfaceProvider: CloudDisplayMembershipSyncing {
    func cloudDisplayMembershipWorkspace(displayID: String, panelID: UUID) async throws -> String? {
        guard let connected = try? await links.connected(machineID: machineID),
              let link = await links.link(machineID: machineID) else {
            throw ProviderError.machineAsleep(machineID)
        }
        let data = try await link.run(arguments: CloudTuiRequests.snapshotArguments(socketPath: connected.socketPath))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: machine),
              state.document.containsCollection("frontend_projections") else {
            throw SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage)
        }
        let clientID = CloudTuiClientPaths().notificationClientID()
        let viewID = panelID.uuidString.lowercased()
        return state.displayMemberships.first {
            $0.displayID == displayID && $0.clientID == clientID && $0.viewID == viewID
        }?.workspaceID
    }

    func syncCloudDisplayMembership(
        displayID: String,
        workspaceID: String,
        panelID: UUID,
        attached: Bool
    ) async throws {
        let resourceID = SurfaceResourceID(machine: machine, kind: .display, key: displayID)
        guard catalog.resources[resourceID]?.kind == .display else {
            throw SurfaceCatalogError.unknownResource(resourceID)
        }
        let token = CloudVMDisplayMembership(
            machine: machine,
            workspaceID: workspaceID,
            displayID: displayID,
            clientID: CloudTuiClientPaths().notificationClientID(),
            viewID: panelID.uuidString.lowercased()
        )
        try await updateCloudDisplayMemberships(workspaceID: workspaceID) { memberships in
            if attached { memberships.insert(token) } else { memberships.remove(token) }
        }
    }

    func removeCloudDisplay(displayID: String, fromWorkspace workspaceID: String) async throws {
        try await updateCloudDisplayMemberships(workspaceID: workspaceID) { memberships in
            memberships = memberships.filter { $0.displayID != displayID }
        }
    }

    /// Rewrites one workspace's membership row, revision-checked and retried
    /// on a conflict. An unchanged set writes nothing.
    private func updateCloudDisplayMemberships(
        workspaceID: String,
        _ change: (inout Set<CloudVMDisplayMembership>) -> Void
    ) async throws {
        guard let connected = try? await links.connected(machineID: machineID),
              let link = await links.link(machineID: machineID) else {
            throw ProviderError.machineAsleep(machineID)
        }
        let projectionID = Self.displayMembershipProjectionID(machine: machine, workspaceID: workspaceID)
        let windowID = CloudVMDisplayMembership.projectionWindowID(machine: machine, workspaceID: workspaceID)
        let idempotencyKey = "cmux-cloud-display-membership-\(UUID().uuidString.lowercased())"
        var lastError: Error?
        for _ in 0..<4 {
            try Task.checkCancellation()
            let data = try await link.run(arguments: CloudTuiRequests.snapshotArguments(socketPath: connected.socketPath))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: machine),
                  state.document.containsCollection("frontend_projections") else {
                throw SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage)
            }
            guard state.workspaceIDs.contains(workspaceID) else {
                throw SurfaceCatalogError.destinationNotFound("workspace \(workspaceID) on \(machine.rawValue)")
            }
            let previousMemberships = Set(state.displayMemberships.filter { $0.workspaceID == workspaceID })
            var memberships = previousMemberships
            change(&memberships)
            let rows = (object["frontend_projections"] as? [[String: Any]]) ?? []
            let row = rows.first { ($0["id"] as? String) == projectionID }
            if row != nil, memberships == previousMemberships { return }
            let projection: [String: Any] = [
                "schema": CloudVMDisplayMembership.projectionSchema,
                "machine_id": machine.rawValue,
                "workspace_id": workspaceID,
                "memberships": memberships.sorted {
                    ($0.displayID, $0.clientID, $0.viewID) < ($1.displayID, $1.clientID, $1.viewID)
                }.map { [
                    "display_id": $0.displayID,
                    "client_id": $0.clientID,
                    "view_id": $0.viewID,
                ] },
            ]
            let expected = row.flatMap { CloudWireNumber.unsigned($0["projection_revision"]) }
            let request = CloudTuiRequests.putCloudDisplayMembershipProjection(
                projectionID: projectionID,
                frontendID: CloudVMDisplayMembership.projectionFrontendID,
                windowID: windowID,
                generation: CloudVMDisplayMembership.projectionGeneration,
                projection: projection,
                expectedProjectionRevision: expected,
                idempotencyKey: idempotencyKey
            )
            do {
                _ = try await link.run(arguments: request)
                scheduleRefresh()
                return
            } catch {
                lastError = error
                guard Self.isRevisionConflict(error) else { throw error }
            }
        }
        throw lastError ?? SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage)
    }

    /// Names (or, with an empty name, un-names) one of this machine's displays
    /// for every client. Revision-checked like a membership write.
    func renameDisplay(displayID: String, name: String) async throws {
        guard displayID.hasPrefix("display:") else { throw SurfaceCatalogError.unknownResource(
            SurfaceResourceID(machine: machine, kind: .display, key: displayID)) }
        guard let connected = try? await links.connected(machineID: machineID),
              let link = await links.link(machineID: machineID) else {
            throw ProviderError.machineAsleep(machineID)
        }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CloudVMDisplayMembership.maxDisplayNameLength))
        let projectionID = Self.displayNamesProjectionID(machine: machine)
        let idempotencyKey = "cmux-cloud-display-name-\(UUID().uuidString.lowercased())"
        var lastError: Error?
        for _ in 0..<4 {
            try Task.checkCancellation()
            let data = try await link.run(arguments: CloudTuiRequests.snapshotArguments(socketPath: connected.socketPath))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: machine),
                  state.document.containsCollection("frontend_projections") else {
                throw SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage)
            }
            var names = state.displayNames
            if trimmed.isEmpty { names.removeValue(forKey: displayID) } else { names[displayID] = trimmed }
            let rows = (object["frontend_projections"] as? [[String: Any]]) ?? []
            let row = rows.first { ($0["id"] as? String) == projectionID }
            if row != nil, names == state.displayNames { return }
            let request = CloudTuiRequests.putCloudDisplayMembershipProjection(
                projectionID: projectionID,
                frontendID: CloudVMDisplayMembership.projectionFrontendID,
                windowID: CloudVMDisplayMembership.namesProjectionWindowID(machine: machine),
                generation: CloudVMDisplayMembership.projectionGeneration,
                projection: [
                    "schema": CloudVMDisplayMembership.namesProjectionSchema,
                    "machine_id": machine.rawValue,
                    "names": names,
                ],
                expectedProjectionRevision: row.flatMap { CloudWireNumber.unsigned($0["projection_revision"]) },
                idempotencyKey: idempotencyKey
            )
            do {
                _ = try await link.run(arguments: request)
                scheduleRefresh()
                return
            } catch {
                lastError = error
                guard Self.isRevisionConflict(error) else { throw error }
            }
        }
        throw lastError ?? SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage)
    }

    /// A rename typed into a display pane's tab. Renames run in order, so an
    /// earlier name cannot land last. Afterwards every pane shows the
    /// display's actual name: a cleared name reads "Display N" again, and a
    /// rename that failed (machine asleep) puts the real name back.
    func renameDisplayFromTab(displayID: String, name: String) {
        let previous = displayRenameLane
        displayRenameLane = Task { [weak self] in
            await previous?.value
            try? await self?.renameDisplay(displayID: displayID, name: name)
            self?.applyDisplayPaneTitles()
        }
    }

    private static func displayNamesProjectionID(machine: SurfaceMachineID) -> String {
        let input = Data("\(machine.rawValue)/\(CloudVMDisplayMembership.namesProjectionSchema)".utf8)
        let digest = SHA256.hash(data: input)
        return "projection_" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func displayMembershipProjectionID(machine: SurfaceMachineID, workspaceID: String) -> String {
        let input = Data("\(machine.rawValue)/\(workspaceID)/\(CloudVMDisplayMembership.projectionSchema)".utf8)
        let digest = SHA256.hash(data: input)
        return "projection_" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
