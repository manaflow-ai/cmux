import Foundation

/// Stable client identities attached to the mobile host, grouped by connection.
struct MobileViewPresenceState {
    private static let maximumClientIDUTF8Count = 128
    private var clientIDByConnectionID: [UUID: String] = [:]

    mutating func record(clientID: String, connectionID: UUID) -> Bool {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= Self.maximumClientIDUTF8Count,
              clientIDByConnectionID[connectionID] == nil else {
            return false
        }
        clientIDByConnectionID[connectionID] = trimmed
        return true
    }

    mutating func removeConnection(id: UUID) -> Set<String> {
        guard let clientID = clientIDByConnectionID.removeValue(forKey: id) else {
            return []
        }
        return [clientID]
    }

    mutating func removeAll() {
        clientIDByConnectionID.removeAll()
    }

    func clientIDs(for connectionID: UUID) -> Set<String>? {
        clientIDByConnectionID[connectionID].map { [$0] }
    }

    /// Versioned presence payload for identified views attached to this runtime.
    var payload: [String: Any] {
        var connectionCountByClientID: [String: Int] = [:]
        for clientID in clientIDByConnectionID.values {
            connectionCountByClientID[clientID, default: 0] += 1
        }
        let views: [[String: Any]] = connectionCountByClientID.keys.sorted().compactMap { clientID in
            guard let connectionCount = connectionCountByClientID[clientID] else { return nil }
            return [
                "client_id": clientID,
                "connection_count": connectionCount,
            ]
        }
        return [
            "version": 1,
            "views": views,
        ]
    }
}

extension MobileHostService {
    func viewPresencePayload() -> [String: Any] {
        viewPresenceState.payload
    }

    @discardableResult
    func recordClientID(_ clientID: String, for connectionID: UUID) -> Bool {
        let inserted = viewPresenceState.record(clientID: clientID, connectionID: connectionID)
        if inserted {
            Self.emitEvent(topic: "workspace.updated", payload: ["reason": "view_presence"])
        }
        return inserted
    }

    func recordViewPresence(
        for request: MobileHostRPCRequest,
        connectionID: UUID,
        authorization: MobileHostConnectionAuthorizationContext
    ) {
        // The Stack-bearer status probe is intentionally unauthenticated and
        // must not be able to spoof or grow attached-view presence.
        guard authorization != .stackBearer || request.method != "mobile.host.status" else {
            return
        }
        let inserted = (request.params["client_id"] as? String)
            .map { recordClientID($0, for: connectionID) } ?? false
        if request.method == "mobile.events.subscribe", !inserted {
            Self.emitEvent(topic: "workspace.updated", payload: ["reason": "view_presence"])
        }
    }
}
