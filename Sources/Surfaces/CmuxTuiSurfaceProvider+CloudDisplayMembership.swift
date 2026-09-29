import CmuxCloud
import CmuxCloudTui
import CmuxSurfaceCatalogModel
import CryptoKit
import Foundation

@MainActor
extension CmuxTuiSurfaceProvider: CloudDisplayMembershipSyncing {
    private static let displayMembershipSchema = "cmux.cloud.workspace-displays.v1"
    private static let displayMembershipFrontend = "cmux-macos-cloud-layout-v1"
    private static let displayMembershipGeneration = "cmux-cloud-display-layout-v1"

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
        guard let connected = try? await links.connected(machineID: machineID),
              let link = await links.link(machineID: machineID) else {
            throw ProviderError.machineAsleep(machineID)
        }
        let clientID = CloudTuiClientPaths().notificationClientID()
        let viewID = panelID.uuidString.lowercased()
        let projectionID = Self.displayMembershipProjectionID(machine: machine, workspaceID: workspaceID)
        let windowID = "cloud-workspace:\(machine.rawValue):\(workspaceID)"
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
            var memberships = Set(state.displayMemberships.filter { $0.workspaceID == workspaceID })
            let token = CloudVMDisplayMembership(
                machine: machine,
                workspaceID: workspaceID,
                displayID: displayID,
                clientID: clientID,
                viewID: viewID
            )
            if attached { memberships.insert(token) } else { memberships.remove(token) }
            let rows = (object["frontend_projections"] as? [[String: Any]]) ?? []
            let row = rows.first { ($0["id"] as? String) == projectionID }
            let previousMemberships = Set(state.displayMemberships.filter { $0.workspaceID == workspaceID })
            if row != nil, memberships == previousMemberships { return }
            let projection: [String: Any] = [
                "schema": Self.displayMembershipSchema,
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
                frontendID: Self.displayMembershipFrontend,
                windowID: windowID,
                generation: Self.displayMembershipGeneration,
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

    private static func displayMembershipProjectionID(machine: SurfaceMachineID, workspaceID: String) -> String {
        let input = Data("\(machine.rawValue)/\(workspaceID)/\(displayMembershipSchema)".utf8)
        let digest = SHA256.hash(data: input)
        return "projection_" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
