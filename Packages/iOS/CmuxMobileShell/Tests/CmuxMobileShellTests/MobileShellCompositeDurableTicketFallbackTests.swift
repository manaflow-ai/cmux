import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellCompositeDurableTicketFallbackTests {
    @Test func reconnectRetriesFreshManualTicketWhenPersistedAttachTokenIsUnauthorized() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expiresAt = now.addingTimeInterval(3600)
        try await pairedStore.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [route],
            attachToken: "stale-token",
            attachTokenExpiresAt: expiresAt,
            attachTokenWorkspaceID: "",
            attachTokenTerminalID: nil,
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: now
        )

        let router = DurableTicketFallbackRouter(
            route: route,
            expiresAt: expiresAt
        )
        let runtime = DurableTicketFallbackRuntime(
            transportFactory: DurableTicketFallbackTransportFactory(router: router),
            now: { now }
        )
        let defaultsSuiteName = "MobileShellCompositeDurableTicketFallbackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults
        )

        let reconnected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")

        #expect(reconnected)
        #expect(store.connectionState == .connected)
        let requests = await router.requests()
        #expect(requests.map(\.method) == [
            "workspace.list",
            "mobile.attach_ticket.create",
            "workspace.list",
            "workspace.list",
        ])
        guard requests.count >= 4 else { return }
        #expect(requests[0].attachToken == "stale-token")
        #expect(requests[0].stackAccessToken == nil)
        #expect(requests[1].attachToken == nil)
        #expect(requests[1].stackAccessToken == "fresh-stack-token")
        #expect(requests[2].attachToken == nil)
        #expect(requests[2].stackAccessToken == "fresh-stack-token")
        #expect(requests[2].workspaceID == nil)
        #expect(requests[3].attachToken == "fresh-token")
        #expect(requests[3].stackAccessToken == nil)
        #expect(requests[3].workspaceID == DurableTicketFallbackRouter.workspaceID)
    }

    @Test func durableAttachTicketPreservesPersistedScope() throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)
        )
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expiresAt = now.addingTimeInterval(3600)
        let router = DurableTicketFallbackRouter(route: route, expiresAt: expiresAt)
        let store = MobileShellComposite(
            runtime: DurableTicketFallbackRuntime(
                transportFactory: DurableTicketFallbackTransportFactory(router: router),
                now: { now }
            )
        )
        let scopedMac = MobilePairedMac(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [route],
            attachToken: "scoped-token",
            attachTokenExpiresAt: expiresAt,
            attachTokenWorkspaceID: "workspace-a",
            attachTokenTerminalID: "terminal-a",
            createdAt: now,
            lastSeenAt: now,
            isActive: true,
            stackUserID: "user-1"
        )
        let scopedTicket = try #require(store.durableAttachTicket(for: scopedMac))
        #expect(scopedTicket.workspaceID == "workspace-a")
        #expect(scopedTicket.terminalID == "terminal-a")

        var unknownScopeMac = scopedMac
        unknownScopeMac.attachTokenWorkspaceID = nil
        #expect(store.durableAttachTicket(for: unknownScopeMac) == nil)
    }
}

private struct DurableTicketFallbackRuntime: MobileSyncRuntime {
    var transportFactory: any CmxByteTransportFactory
    var stackAccessTokenProvider: @Sendable () async throws -> String = { "fresh-stack-token" }
    var stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "fresh-stack-token" }
    var rpcRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var now: @Sendable () -> Date
    var supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale]
    var pairingRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var supportsServerPushEvents: Bool = false
}

private struct DurableTicketFallbackTransportFactory: CmxByteTransportFactory {
    let router: DurableTicketFallbackRouter

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        DurableTicketFallbackTransport(router: router)
    }
}

private actor DurableTicketFallbackTransport: CmxByteTransport {
    private let router: DurableTicketFallbackRouter
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(router: DurableTicketFallbackRouter) {
        self.router = router
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        if isClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for payload in payloads {
            let response = try await router.response(for: payload)
            deliver(response)
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func deliver(_ frame: Data) {
        if receiveWaiters.isEmpty {
            pendingFrames.append(frame)
            return
        }
        receiveWaiters.removeFirst().resume(returning: frame)
    }
}

private actor DurableTicketFallbackRouter {
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
            return try Self.errorFrame(
                id: request.id,
                code: "unauthorized",
                message: "attach token no longer exists"
            )
        case ("mobile.attach_ticket.create", _):
            return try attachTicketFrame(id: request.id)
        case ("workspace.list", nil) where request.stackAccessToken == "fresh-stack-token" && request.workspaceID == nil:
            return try Self.errorFrame(
                id: request.id,
                code: "forbidden",
                message: "Full workspace list requires Mac-wide authorization"
            )
        case ("workspace.list", "fresh-token") where request.workspaceID == Self.workspaceID:
            return try Self.workspaceListFrame(id: request.id)
        default:
            return try Self.errorFrame(
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
        return try Self.resultFrame(id: id, result: ["ticket": ticketObject])
    }

    private static func workspaceListFrame(id: String?) throws -> Data {
        try resultFrame(id: id, result: [
            "workspaces": [
                [
                    "id": workspaceID,
                    "title": "Fresh Workspace",
                    "current_directory": "/Users/test/project",
                    "is_selected": true,
                    "terminals": [],
                ],
            ],
        ])
    }

    private static func resultFrame(id: String?, result: [String: Any]) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": true,
            "result": result,
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }

    private static func errorFrame(id: String?, code: String, message: String) throws -> Data {
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

private struct DurableTicketFallbackRequest: Sendable {
    var id: String?
    var method: String?
    var workspaceID: String?
    var attachToken: String?
    var stackAccessToken: String?

    init(payload: Data) throws {
        let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let params = request?["params"] as? [String: Any]
        let auth = request?["auth"] as? [String: Any]
        id = request?["id"] as? String
        method = request?["method"] as? String
        workspaceID = params?["workspace_id"] as? String
        attachToken = auth?["attach_token"] as? String
        stackAccessToken = auth?["stack_access_token"] as? String
    }
}
