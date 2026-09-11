import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing
import SQLite3
@testable import CmuxHive

@Suite
@MainActor
struct HivePairingSecurityTests {
    @Test(arguments: ["192.168.1.2:7333", "mac.tailnet.ts.net:7333", "example.com:7333", "127.0.0.1:7333"])
    func freshPairingRejectsUntrustedDestinations(input: String) {
        #expect(throws: HivePairingError.tailscaleRequired) {
            try HivePairingRequest(input: input, userID: "owner", email: nil, allowsLoopback: false)
        }
    }

    @Test
    func debugLoopbackRequiresExplicitOptIn() throws {
        let request = try HivePairingRequest(input: "127.0.0.1:7333", userID: "owner", email: nil, allowsLoopback: true)
        #expect(request.route.kind == .debugLoopback)
        #expect(request.authorization == nil)
    }

    @Test
    func sharedPairingURLPreservesExactEndpointAndAccountPreflight() throws {
        let code = "cmux-ios://attach?v=2&r=100.64.0.1:7333&ub=owner"
        let request = try HivePairingRequest(input: code, userID: "owner", email: nil, allowsLoopback: false)
        #expect(request.authorization?.authorizes(host: "100.64.0.1", port: 7333) == true)
        #expect(request.authorization?.authorizes(host: "100.64.0.1", port: 7444) == false)
        #expect(throws: HivePairingError.accountMismatch) {
            try HivePairingRequest(input: code, userID: "other-owner", email: nil, allowsLoopback: false)
        }
    }

    @Test
    func identityStatusCannotPairThisExactInstance() throws {
        let request = try HivePairingRequest(input: "100.64.0.1:7333", userID: "owner", email: nil, allowsLoopback: false)
        let status = try MobileHostStatusResponse.decode(Data(#"{"mac_device_id":"mac-a","mac_instance_tag":"default"}"#.utf8))
        #expect(throws: HivePairingError.thisMac) {
            try request.verifiedIdentity(status: status, ownDeviceID: "mac-a", ownInstanceTag: "default")
        }
        #expect(try request.verifiedIdentity(status: status, ownDeviceID: "mac-a", ownInstanceTag: "other").instanceTag == "default")
    }

    @Test
    func publicStatusWithoutIdentityCannotAuthorizeADevice() throws {
        let request = try HivePairingRequest(input: "100.64.0.1:7333", userID: "owner", email: nil, allowsLoopback: false)
        let status = try MobileHostStatusResponse.decode(Data(#"{"capabilities":[]}"#.utf8))
        #expect(throws: HivePairingError.missingIdentity) {
            try request.verifiedIdentity(status: status, ownDeviceID: "mac-a", ownInstanceTag: "default")
        }
    }

    @Test
    func paddedSelfIdentityIsRejected() throws {
        let request = try HivePairingRequest(input: "100.64.0.1:7333", userID: "owner", email: nil, allowsLoopback: false)
        let status = try MobileHostStatusResponse.decode(Data(#"{"mac_device_id":"  mac-a  ","mac_instance_tag":"default"}"#.utf8))
        #expect(throws: HivePairingError.thisMac) {
            try request.verifiedIdentity(status: status, ownDeviceID: "mac-a", ownInstanceTag: "default")
        }
    }

    @Test
    func pairingLinkRequiresItsNamedDeviceIdentity() throws {
        let route = try CmxAttachRoute(id: "tailscale", kind: .tailscale, endpoint: .hostPort(host: "100.64.0.1", port: 7333))
        let ticket = try CmxAttachTicket(workspaceID: "", terminalID: nil, macDeviceID: "mac-b", macDisplayName: nil, routes: [route])
        let payload = try CmxAttachTicketCompactCoder().encode(ticket, routeDisclosureMode: .legacyPrivateNetworkCompatibility).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let link = "cmux-ios://attach?payload=\(payload)"
        let request = try HivePairingRequest(input: link, userID: "owner", email: nil, allowsLoopback: false)
        let status = try MobileHostStatusResponse.decode(Data(#"{"mac_device_id":"mac-c","mac_instance_tag":"default"}"#.utf8))
        #expect(throws: HivePairingError.identityMismatch) {
            try request.verifiedIdentity(status: status, ownDeviceID: "mac-a", ownInstanceTag: "default")
        }
    }

    @Test
    func blankTicketIdentityUsesTheAuthenticatedHostIdentity() throws {
        let route = try CmxAttachRoute(id: "tailscale", kind: .tailscale, endpoint: .hostPort(host: "100.64.0.1", port: 7333))
        let ticket = try CmxAttachTicket(workspaceID: "", terminalID: nil, macDeviceID: " \n ", macDisplayName: nil, routes: [route])
        let payload = try CmxAttachTicketCompactCoder().encode(ticket, routeDisclosureMode: .legacyPrivateNetworkCompatibility).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let request = try HivePairingRequest(input: "cmux-ios://attach?payload=\(payload)", userID: "owner", email: nil, allowsLoopback: false)
        #expect(request.expectedDeviceID == nil)
        let status = try MobileHostStatusResponse.decode(Data(#"{"mac_device_id":"mac-b","mac_instance_tag":"default"}"#.utf8))
        #expect(try request.verifiedIdentity(status: status, ownDeviceID: "mac-a", ownInstanceTag: "default").macDeviceID == "mac-b")
    }

    @Test
    func failedEndpointGrantRollsBackPairingMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        _ = try await fixture.store.loadAll(stackUserID: "owner", teamID: "team")
        var database: OpaquePointer?
        let path = fixture.directory.appendingPathComponent("pairings.sqlite3").path
        try #require(sqlite3_open(path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = "CREATE TRIGGER reject_test_grant BEFORE INSERT ON legacy_tailscale_route_grants BEGIN SELECT RAISE(ABORT, 'test grant failure'); END;"
        try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        let controller = fixture.controller(peer: PairingPeer())
        defer { controller.stop() }
        await #expect(throws: HivePairingError.storageFailed) {
            try await controller.pair("100.64.0.1:7333")
        }
        #expect(try await fixture.store.loadAll(stackUserID: "owner", teamID: "team").isEmpty)
    }

    @Test
    func storedMetadataWithoutAnEndpointGrantIsNotAPairing() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let route = try CmxAttachRoute(id: "tailscale", kind: .tailscale, endpoint: .hostPort(host: "100.64.0.1", port: 7333))
        try await fixture.store.upsert(
            macDeviceID: "mac-b", displayName: "Unverified metadata", routes: [route],
            instanceTag: "default", markActive: false, stackUserID: "owner", teamID: "team", now: Date()
        )
        let controller = fixture.controller(peer: PairingPeer())
        try await controller.load()
        #expect(controller.computers.isEmpty)
        controller.stop()
    }

    @Test
    func pairingPersistsOnlyTheEnteredEndpointAfterAuthenticatedStatus() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let peer = PairingPeer()
        let controller = fixture.controller(peer: peer)
        let computer = try await controller.pair("100.64.0.1:7333")
        #expect(computer.deviceID == "mac-b")
        #expect(computer.instanceTag == "default")
        #expect(computer.displayName == "Remote Mac")
        #expect(await peer.methods == ["workspace.list", "mobile.host.status"])
        #expect(await peer.tokens == ["test-owner-token", "test-owner-token"])
        let entered = try CmxAttachRoute(id: "new-route-id", kind: .tailscale, endpoint: .hostPort(host: "100.64.0.1", port: 7333))
        let discovered = try CmxAttachRoute(id: "tailscale", kind: .tailscale, endpoint: .hostPort(host: "100.64.0.2", port: 7333))
        #expect(computer.authorization(for: entered)?.macDeviceID == "mac-b")
        #expect(computer.authorization(for: discovered) == nil)
        controller.stop()
        let restarted = fixture.controller(peer: PairingPeer())
        try await restarted.load()
        #expect(restarted.computers.first?.authorization(for: entered) != nil)
        #expect(restarted.computers.first?.authorization(for: discovered) == nil)
        restarted.stop()
    }

    @Test
    func unpairRemovesOnlyTheSelectedInstanceAndItsGrant() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let first = fixture.controller(peer: PairingPeer())
        let computer = try await first.pair("100.64.0.1:7333")
        let second = fixture.controller(peer: PairingPeer(tag: "nightly"))
        _ = try await second.pair("100.64.0.1:7444")
        let otherTeam = fixture.controller(peer: PairingPeer(), teamID: "other-team")
        _ = try await otherTeam.pair("100.64.0.1:7555")
        try await first.load()
        #expect(first.computers.count == 2)
        try await first.unpair(id: computer.id)
        #expect(first.computers.map(\.instanceTag) == ["nightly"])
        try await otherTeam.load()
        #expect(otherTeam.computers.count == 1)
        #expect(otherTeam.computers[0].instanceTag == "default")
        let repaired = fixture.controller(peer: PairingPeer())
        let newComputer = try await repaired.pair("100.64.0.1:7666")
        let removedEndpoint = try CmxAttachRoute(id: "tailscale", kind: .tailscale, endpoint: .hostPort(host: "100.64.0.1", port: 7333))
        #expect(newComputer.authorization(for: removedEndpoint) == nil)
        first.stop()
        second.stop()
        otherTeam.stop()
        repaired.stop()
    }

    @Test
    func unpairHoldsThePairingLockUntilItsDeleteFinishes() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let controller = fixture.controller(peer: PairingPeer())
        let computer = try await controller.pair("100.64.0.1:7333")
        let unpairing = Task { try await controller.unpair(id: computer.id) }
        // Let the delete reach its store I/O suspension before a pair races it.
        for _ in 0..<3 { await Task.yield() }
        await #expect(throws: HivePairingError.busy) {
            try await controller.pair("100.64.0.1:7444")
        }
        try await unpairing.value
        #expect(controller.computers.isEmpty)
        // The fake peer serves one pairing per controller; a fresh controller
        // proves the scope is free again once the delete has finished.
        let repaired = fixture.controller(peer: PairingPeer())
        let replacement = try await repaired.pair("100.64.0.1:7444")
        #expect(repaired.computers.map(\.id) == [replacement.id])
        controller.stop()
        repaired.stop()
    }

    @Test
    func cancelledDisconnectStillClosesItsTransport() async throws {
        let peer = PairingPeer()
        let runtime = PairingRuntime(transportFactory: PairingFactory(peer: peer))
        let request = try HivePairingRequest(input: "100.64.0.1:7333", userID: "owner", email: nil, allowsLoopback: false)
        let client = MobileCoreRPCClient(
            runtime: runtime, route: request.route, ticket: request.ticket,
            allowsStackAuthFallback: false, userTailscalePairingAuthorization: request.authorization,
            sessionPurpose: .probe
        )
        _ = try await client.sendRequestAndAuthenticatedHostStatus(
            MobileCoreRPCClient.requestData(method: "workspace.list", params: [:]),
            timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds,
            hostStatusTimeoutNanoseconds: { runtime.pairingRequestTimeoutNanoseconds }
        )
        let cleanup = Task {
            await client.disconnect()
            await client.disconnectAndWaitForTransportDrain()
        }
        cleanup.cancel()
        await cleanup.value
        #expect(await peer.closed)
    }

    @Test
    func stopDuringHostStatusDoesNotPersistAuthorization() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let peer = PairingPeer(holdStatus: true)
        let controller = fixture.controller(peer: peer)
        let pairing = Task { try await controller.pair("100.64.0.1:7333") }
        var requests = peer.statusRequests.makeAsyncIterator()
        _ = await requests.next()
        controller.stop()
        do {
            _ = try await pairing.value
            Issue.record("A stopped pairing completed")
        } catch {}
        let records = try await fixture.store.loadAll(stackUserID: "owner", teamID: "team")
        #expect(records.isEmpty)
        #expect(controller.computers.isEmpty)
    }

    @Test
    func missingAuthenticatedIdentityLeavesNoLocalPairing() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let controller = fixture.controller(peer: PairingPeer(includeIdentity: false))
        await #expect(throws: HivePairingError.missingIdentity) {
            try await controller.pair("100.64.0.1:7333")
        }
        #expect(try await fixture.store.loadAll(stackUserID: "owner", teamID: "team").isEmpty)
        controller.stop()
    }

    private struct Fixture {
        let directory: URL
        let store: MobilePairedMacStore

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("hive-tests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try MobilePairedMacStore(databaseURL: directory.appendingPathComponent("pairings.sqlite3"))
        }

        @MainActor
        func controller(peer: PairingPeer, teamID: String = "team") -> HivePairingController {
            HivePairingController(
                store: store, runtime: PairingRuntime(transportFactory: PairingFactory(peer: peer)),
                userID: "owner", teamID: teamID, email: nil,
                ownDeviceID: "mac-a", ownInstanceTag: "default", allowsLoopback: false
            )
        }

        func removeFiles() { try? FileManager.default.removeItem(at: directory) }
    }
}

private struct PairingRuntime: MobileSyncRuntime {
    let transportFactory: any CmxByteTransportFactory
    let stackAccessTokenProvider: @Sendable () async throws -> String = { "test-owner-token" }
    let stackAccessTokenForStatusProvider: @Sendable () async -> String? = { "test-owner-token" }
    let stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "test-owner-token" }
    let supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale]
    let rpcRequestTimeoutNanoseconds: UInt64 = 2_000_000_000
    let pairingRequestTimeoutNanoseconds: UInt64 = 2_000_000_000
    let now: @Sendable () -> Date = { Date() }
    let supportsServerPushEvents = true
}

private struct PairingFactory: CmxByteTransportFactory {
    let peer: PairingPeer
    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport { peer }
}

private actor PairingPeer: CmxByteTransport {
    nonisolated let statusRequests: AsyncStream<Void>
    private let statusContinuation: AsyncStream<Void>.Continuation
    private let tag: String
    private let holdStatus: Bool
    private let includeIdentity: Bool
    private var queued: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Never>] = []
    private(set) var closed = false
    private(set) var methods: [String] = []
    private(set) var tokens: [String] = []

    init(tag: String = "default", holdStatus: Bool = false, includeIdentity: Bool = true) {
        self.tag = tag
        self.holdStatus = holdStatus
        self.includeIdentity = includeIdentity
        (statusRequests, statusContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if closed { return nil }
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        for payload in try MobileSyncFrameCodec.decodeFrames(from: &buffer) {
            let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let method = try #require(request["method"] as? String)
            methods.append(method)
            let auth = request["auth"] as? [String: Any]
            tokens.append(auth?["stack_access_token"] as? String ?? "")
            var result: [String: Any] = ["workspaces": []]
            if method == "mobile.host.status" {
                statusContinuation.yield(())
                if holdStatus { continue }
                result = includeIdentity ? [
                    "mac_device_id": "mac-b", "mac_instance_tag": tag, "mac_display_name": "Remote Mac"
                ] : ["capabilities": []]
            }
            let response = try JSONSerialization.data(withJSONObject: [
                "id": request["id"] ?? "", "ok": true, "result": result
            ])
            let frame = try MobileSyncFrameCodec.encodeFrame(response)
            if waiters.isEmpty { queued.append(frame) } else { waiters.removeFirst().resume(returning: frame) }
        }
    }

    func close() async {
        closed = true
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters = []
        statusContinuation.finish()
    }
}
