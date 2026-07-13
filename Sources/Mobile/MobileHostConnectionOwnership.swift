import Foundation

@MainActor
struct MobileHostConnectionOwnership {
    private struct InteractionIdentity: Hashable {
        var clientID: String
        var sessionID: String
    }

    private var clientIDsByConnectionID: [UUID: Set<String>] = [:]
    private var interactionIdentitiesByConnectionID: [UUID: Set<InteractionIdentity>] = [:]

    mutating func recordRequest(params: [String: Any], connectionID: UUID) {
        if let clientID = Self.clientID(from: params) {
            recordClientID(clientID, connectionID: connectionID)
        }
        guard let identity = Self.interactionIdentity(from: params) else { return }
        var identities = interactionIdentitiesByConnectionID[connectionID] ?? []
        guard identities.contains(identity) || identities.count < 64 else { return }
        identities.insert(identity)
        interactionIdentitiesByConnectionID[connectionID] = identities
    }

    mutating func recordClientID(_ clientID: String, connectionID: UUID) {
        clientIDsByConnectionID[connectionID, default: []].insert(clientID)
    }

    mutating func retireConnection(_ connectionID: UUID) {
        let clientIDs = clientIDsByConnectionID.removeValue(forKey: connectionID) ?? []
        let liveClientIDs = clientIDsByConnectionID.values.reduce(into: Set<String>()) {
            $0.formUnion($1)
        }
        TerminalController.shared.clearMobileViewportReports(
            clientIDs: clientIDs.subtracting(liveClientIDs),
            reason: "mobile.connection.closed"
        )

        let identities = interactionIdentitiesByConnectionID.removeValue(forKey: connectionID) ?? []
        let liveIdentities = interactionIdentitiesByConnectionID.values.reduce(into: Set<InteractionIdentity>()) {
            $0.formUnion($1)
        }
        let retiredIdentities = identities.subtracting(liveIdentities)
        TerminalController.shared.clearMobileInteractionEpochs(
            clientSessions: retiredIdentities.map { ($0.clientID, $0.sessionID) }
        )
    }

    mutating func reset() {
        clientIDsByConnectionID.removeAll()
        interactionIdentitiesByConnectionID.removeAll()
    }

    func clientIDs(connectionID: UUID) -> Set<String>? {
        clientIDsByConnectionID[connectionID]
    }

    private nonisolated static func clientID(from params: [String: Any]) -> String? {
        let trimmed = (params["client_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private nonisolated static func interactionIdentity(
        from params: [String: Any]
    ) -> InteractionIdentity? {
        guard let clientID = clientID(from: params) else { return nil }
        let explicitSession = (params["interaction_session_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID: String
        if let explicitSession, !explicitSession.isEmpty {
            guard explicitSession.utf8.count <= 128 else { return nil }
            sessionID = explicitSession
        } else {
            guard params["interaction_epoch"] is NSNumber else { return nil }
            sessionID = ""
        }
        return InteractionIdentity(clientID: clientID, sessionID: sessionID)
    }
}
