import CmuxNextSettings
import Foundation

/// The server surfaces' wire (webviews/src/pages/server-cards/server/types.ts): the owner's
/// snapshot, connection, Chief placement and a found server as page JSON (times in Unix ms). The
/// key fingerprint stays here: the page gets the offer's QR image, never its payload.
enum ServerWire {
    static func connection(_ connection: ServerConnection) -> JSONValue {
        switch connection {
        case .connecting: ["state": "connecting"]
        case .connected: ["state": "connected"]
        case let .unavailable(reason): ["state": "unavailable", "reason": .string(reason)]
        }
    }

    static func snapshot(_ snapshot: ServerSnapshot, qr: (String) -> String?) -> JSONValue {
        .object([
            "hostName": .string(snapshot.hostName),
            "platform": .string(snapshot.platform.rawValue),
            "enabled": .bool(snapshot.enabled),
            "roles": .array(snapshot.roles.map { ["role": .string($0.role.rawValue), "state": .string($0.state.rawValue)] }),
            "terminals": JSONValue(snapshot.terminals),
            "appServers": .array(snapshot.appServers.map { app in
                ["appID": .string(app.appID), "name": .string(app.name), "state": .string(app.state.rawValue),
                 "holdsLease": .bool(app.holdsLease), "durability": .string(app.durability.rawValue)]
            }),
            "databases": .array(snapshot.databases.map { database in
                ["app": .string(database.app), "sizeBytes": .number(Double(database.sizeBytes)),
                 "quotaBytes": .number(Double(database.quotaBytes))]
            }),
            "browser": browser(snapshot.browser),
            "automations": JSONValue(snapshot.automations),
            "pairing": pairing(snapshot.pairing, qr: qr),
            "devices": .array(snapshot.devices.map { device in
                var entry: [String: JSONValue] = ["id": .string(device.id), "name": .string(device.name), "kind": .string(device.kind.rawValue)]
                if let seen = device.lastSeen { entry["lastSeen"] = time(seen) }
                return .object(entry)
            }),
            "checks": .array(snapshot.checks.map { .string($0.rawValue) }),
            "alerts": .array(snapshot.alerts.map(alert)),
            "store": ["version": .string(snapshot.store.version), "channel": .string(snapshot.store.channel),
                      "pinned": .bool(snapshot.store.pinned)],
        ])
    }

    static func chief(_ status: ChiefPlacementStatus) -> JSONValue {
        var entry: [String: JSONValue] = ["serverName": .string(status.serverName)]
        switch status.state {
        case .ready: entry["state"] = "ready"
        case .thinking: entry["state"] = "thinking"
        case .notAnswering: entry["state"] = "notAnswering"
        }
        if let reply = status.lastReply { entry["lastReply"] = time(reply) }
        return .object(entry)
    }

    static func candidate(_ candidate: PairingCandidate) -> JSONValue {
        var entry: [String: JSONValue] = [
            "code": .string(candidate.code), "name": .string(candidate.name), "os": .string(candidate.os),
            "version": .string(candidate.version), "words": .array(candidate.words.map { .string($0) }),
            "teams": .array(candidate.teams.map { ["id": .string($0.id), "name": .string($0.name)] }),
            "isChiefBrain": .bool(candidate.isChiefBrain),
        ]
        if let region = candidate.region { entry["region"] = .string(region) }
        return .object(entry)
    }

    private static func time(_ date: Date) -> JSONValue {
        .number((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func browser(_ state: ServerBrowserState) -> JSONValue {
        switch state {
        case .off: ["state": "off"]
        case .idle: ["state": "idle"]
        case let .running(pages): ["state": "running", "pages": JSONValue(pages)]
        case .unavailable: ["state": "unavailable"]
        }
    }

    private static func pairing(_ state: ServerPairingState, qr: (String) -> String?) -> JSONValue {
        switch state {
        case let .unpaired(offer):
            guard let offer else { return ["state": "unpaired"] }
            var entry: [String: JSONValue] = [
                "code": .string(offer.code), "expiresAt": time(offer.expiresAt), "words": .array(offer.words.map { .string($0) }),
            ]
            if let image = qr(offer.qrPayload) { entry["qr"] = .string(image) }
            return ["state": "unpaired", "offer": .object(entry)]
        case .pairing:
            return ["state": "pairing"]
        case let .paired(info):
            return ["state": "paired", "team": .string(info.team), "owner": .string(info.owner), "hostID": .string(info.hostID)]
        }
    }

    private static func alert(_ alert: HealthAlert) -> JSONValue {
        var entry: [String: JSONValue] = [
            "check": .string(alert.check.rawValue), "severity": .string(alert.severity.rawValue), "title": .string(alert.title),
            "body": .string(alert.body), "raisedAt": time(alert.raisedAt),
        ]
        if let fix = alert.fix {
            entry["fix"] = ["title": .string(fix.title), "needsAdmin": .bool(fix.needsAdmin), "opensSettings": .bool(fix.opensSettings)]
        }
        if let resolved = alert.resolvedAt { entry["resolvedAt"] = time(resolved) }
        return .object(entry)
    }
}
