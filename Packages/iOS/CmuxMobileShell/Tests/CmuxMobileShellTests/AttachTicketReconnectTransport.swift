import CMUXMobileCore
import CmuxMobileRPC
import Foundation

actor AttachTicketReconnectTransport: CmxByteTransportFactory, CmxByteTransport {
    private let ticketRoute: CmxAttachRoute
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []

    init(ticketRoute: CmxAttachRoute) {
        self.ticketRoute = ticketRoute
    }

    nonisolated func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        self
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for payload in payloads {
            guard let parsed = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
                  let response = try response(method: parsed["method"] as? String, id: parsed["id"] as? String) else {
                continue
            }
            deliver(response)
        }
    }

    func close() async {}

    private func response(method: String?, id: String?) throws -> Data? {
        switch method {
        case "mobile.attach_ticket.create":
            return try Self.resultFrame(id: id, result: ["ticket": ticketObject()])
        case "workspace.list", "mobile.workspace.list":
            return try Self.resultFrame(id: id, result: [
                "workspaces": [
                    [
                        "id": "trusted-workspace",
                        "title": "Trusted Workspace",
                        "is_selected": true,
                        "terminals": [],
                    ],
                ],
            ])
        case "mobile.host.status":
            return try Self.resultFrame(id: id, result: [
                "terminal_fidelity": "render_grid",
                "capabilities": [:],
            ])
        default:
            return nil
        }
    }

    private func ticketObject() throws -> Any {
        let ticket = try CmxAttachTicket(
            workspaceID: "trusted-workspace",
            terminalID: nil,
            macDeviceID: "trusted-mac",
            macDisplayName: "Trusted Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [ticketRoute],
            expiresAt: Date().addingTimeInterval(3600),
            authToken: "ticket-secret"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(ticket))
    }

    private func deliver(_ frame: Data) {
        if receiveWaiters.isEmpty {
            pendingFrames.append(frame)
            return
        }
        let waiter = receiveWaiters.removeFirst()
        waiter.resume(returning: frame)
    }

    private static func resultFrame(id: String?, result: [String: Any]) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": true,
            "result": result,
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }
}
