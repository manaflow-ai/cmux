import CMUXMobileCore
import Foundation

enum MobileAttachTicketStoreError: Error {
    case noRoutes
    case invalidAttachURL
}

final class MobileAttachTicketStore {
    private struct Record {
        let ticket: CmxAttachTicket
        let issuedAt: Date
    }

    private var records: [String: Record] = [:]

    func createTicket(
        workspaceID: String,
        terminalID: String?,
        routes: [CmxAttachRoute],
        ttl: TimeInterval,
        now: Date = Date()
    ) throws -> CmxAttachTicket {
        pruneExpired(now: now)
        guard !routes.isEmpty else {
            throw MobileAttachTicketStoreError.noRoutes
        }

        let ticket = try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: MobileHostIdentity.deviceID(),
            macDisplayName: MobileHostIdentity.displayName(),
            routes: routes,
            expiresAt: now.addingTimeInterval(max(30, ttl))
        )
        records[key(workspaceID: workspaceID, terminalID: terminalID)] = Record(
            ticket: ticket,
            issuedAt: now
        )
        return ticket
    }

    func payload(for ticket: CmxAttachTicket) throws -> [String: Any] {
        [
            "ticket": try Self.jsonObject(ticket),
            "attach_url": try attachURL(for: ticket).absoluteString,
            "expires_at": ISO8601DateFormatter().string(from: ticket.expiresAt),
            "routes": ticket.routes.map(\.mobileHostJSONObject)
        ]
    }

    private func attachURL(for ticket: CmxAttachTicket) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ticket)
        let payload = Self.base64URLEncode(data)
        guard let url = URL(string: "cmux-ios://attach?v=\(ticket.version)&payload=\(payload)") else {
            throw MobileAttachTicketStoreError.invalidAttachURL
        }
        return url
    }

    private func pruneExpired(now: Date) {
        records = records.filter { $0.value.ticket.expiresAt > now }
    }

    private func key(workspaceID: String, terminalID: String?) -> String {
        "\(workspaceID):\(terminalID ?? "*")"
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum MobileHostIdentity {
    private static let deviceIDKey = "mobileHost.deviceID"

    static func deviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: deviceIDKey)
        return generated
    }

    static func displayName() -> String? {
        Host.current().localizedName
    }
}
