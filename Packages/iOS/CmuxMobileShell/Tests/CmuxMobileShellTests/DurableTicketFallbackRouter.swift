import CMUXMobileCore
import CmuxMobileRPC
import Foundation

actor DurableTicketFallbackRouter {
    static let workspaceID = "11111111-1111-4111-8111-111111111111"

    private let route: CmxAttachRoute
    private let expiresAt: Date
    private var recordedRequests: [DurableTicketFallbackRequest] = []

    init(route: CmxAttachRoute, expiresAt: Date) {
        self.route = route
        self.expiresAt = expiresAt
    }

    func response(for payload: Data) throws -> Data {
        let request = try DurableTicketFallbackRequest(payload: payload)
        recordedRequests.append(request)
        switch (request.method, request.attachToken) {
        case ("workspace.list", "stale-token"):
            return try errorFrame(
                id: request.id,
                code: "unauthorized",
                message: "attach token no longer exists"
            )
        case ("mobile.attach_ticket.create", _):
            return try attachTicketFrame(id: request.id)
        case ("workspace.list", nil) where request.stackAccessToken == "fresh-stack-token" && request.workspaceID == nil:
            return try errorFrame(
                id: request.id,
                code: "forbidden",
                message: "Full workspace list requires Mac-wide authorization"
            )
        case ("workspace.list", "scoped-token") where request.workspaceID == Self.workspaceID:
            return try workspaceListFrame(id: request.id)
        case ("workspace.list", "fresh-token") where request.workspaceID == Self.workspaceID:
            return try workspaceListFrame(id: request.id)
        default:
            return try errorFrame(
                id: request.id,
                code: "unexpected_request",
                message: "Unexpected request \(request.method ?? "nil")"
            )
        }
    }

    func requests() -> [DurableTicketFallbackRequest] {
        recordedRequests
    }

    private func attachTicketFrame(id: String?) throws -> Data {
        let ticket = try CmxAttachTicket(
            workspaceID: Self.workspaceID,
            terminalID: nil,
            macDeviceID: "mac-a",
            macDisplayName: "Desk Mac",
            routes: [route],
            expiresAt: expiresAt,
            authToken: "fresh-token"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let ticketObject = try JSONSerialization.jsonObject(with: encoder.encode(ticket))
        return try resultFrame(id: id, result: ["ticket": ticketObject])
    }

    private func workspaceListFrame(id: String?) throws -> Data {
        try resultFrame(id: id, result: [
            "workspaces": [
                [
                    "id": Self.workspaceID,
                    "title": "Fresh Workspace",
                    "current_directory": "/Users/test/project",
                    "is_selected": true,
                    "terminals": [],
                ],
            ],
        ])
    }

    private func resultFrame(id: String?, result: [String: Any]) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": true,
            "result": result,
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }

    private func errorFrame(id: String?, code: String, message: String) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": false,
            "error": [
                "code": code,
                "message": message,
            ],
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }
}
