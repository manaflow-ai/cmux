import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the connection lifecycle carved into
/// ``MobileConnectionCoordinator``, exercised through the
/// ``MobileShellComposite`` facade: manual-host validation, pairing-code
/// failure paths, ticket expiry, paired-Mac persistence + reconnect + forget,
/// and authorization-failure surfacing.
@MainActor
@Suite struct MobileConnectionCoordinatorTests {
    @Test func manualHostRejectsInvalidHostWithoutDialing() async throws {
        let router = ConnectionTestRouter()
        let store = signedInStore(router: router)

        await store.connectManualHost(name: "Bad", host: "not a host!", port: 7777)

        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError != nil)
        #expect(await router.sentRequests().isEmpty)
    }

    @Test func manualHostRejectsInvalidPortWithoutDialing() async throws {
        let router = ConnectionTestRouter()
        let store = signedInStore(router: router)

        await store.connectManualHost(name: "Bad", host: "100.71.210.41", port: 0)

        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError != nil)
        #expect(await router.sentRequests().isEmpty)
    }

    @Test func invalidPairingCodeFailsWithLocalizedError() async throws {
        let router = ConnectionTestRouter()
        let store = signedInStore(router: router)

        let result = await store.connectPairingURLResult("cmux-ios://attach?v=1&payload=garbage")

        #expect(result == .failed)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError != nil)
    }

    @Test func expiredAttachTicketRejectsBeforeSendingAnyRequest() async throws {
        let expiry = Date().addingTimeInterval(60)
        let router = ConnectionTestRouter()
        let runtime = TestShellSyncRuntime(
            transportFactory: ShellRouterTransportFactory(router: router, pusher: ShellEventPusher()),
            now: { expiry.addingTimeInterval(1) },
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()

        let ticket = try ShellTestFrames.liveTicket(expiresAt: expiry)
        let result = await store.connectPairingURLResult(try ShellTestFrames.attachURL(for: ticket))

        #expect(result == .failed)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError != nil)
        #expect(await router.sentRequests().isEmpty)
    }

    @Test func successfulConnectPersistsActivePairedMacAndForgetRemovesIt() async throws {
        let router = ConnectionTestRouter()
        let pairedMacs = InMemoryPairedMacStore()
        let store = signedInStore(router: router, pairedMacStore: pairedMacs)

        let connected = await store.connectPairingURL(try ShellTestFrames.attachURL(for: ShellTestFrames.liveTicket()))

        try #require(connected)
        let active = try #require(try await pairedMacs.activeMac())
        #expect(active.macDeviceID == "test-mac")
        #expect(store.connectedHostName == "Test Mac")

        store.disconnectAndForgetActiveMac()

        #expect(store.connectionState == .disconnected)
        #expect(!store.connectionRequiresReauth)
        try await waitUntilAsync { try await pairedMacs.activeMac() == nil }
        #expect(try await pairedMacs.loadAll().isEmpty)
    }

    @Test func reconnectActiveMacRemintsTicketAndConnects() async throws {
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56584)
        )
        let router = ConnectionTestRouter(attachTicketRoute: route)
        let pairedMacs = InMemoryPairedMacStore()
        try await pairedMacs.upsert(
            macDeviceID: "saved-mac",
            displayName: "Saved Mac",
            routes: [route],
            markActive: true,
            stackUserID: nil
        )
        let store = signedInStore(router: router, pairedMacStore: pairedMacs)

        let reconnected = await store.reconnectActiveMacIfAvailable(stackUserID: nil)

        #expect(reconnected)
        #expect(store.connectionState == .connected)
        #expect(store.connectedHostName == "Saved Mac")
        let methods = await router.sentRequests().compactMap(\.method)
        #expect(methods.first == "mobile.attach_ticket.create")
        #expect(methods.contains("workspace.list"))
    }

    @Test func unauthorizedConnectSurfacesReauthInsteadOfRetry() async throws {
        let router = ConnectionTestRouter(workspaceList: .unauthorized)
        let store = signedInStore(router: router)

        let result = await store.connectPairingURLResult(try ShellTestFrames.attachURL(for: ShellTestFrames.liveTicket()))

        #expect(result == .failed)
        #expect(store.connectionRequiresReauth)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectionError != nil)
    }

    @Test func cancelPairingClearsErrorAndDisconnects() async throws {
        let router = ConnectionTestRouter(workspaceList: .unauthorized)
        let store = signedInStore(router: router)
        _ = await store.connectPairingURLResult(try ShellTestFrames.attachURL(for: ShellTestFrames.liveTicket()))
        #expect(store.connectionError != nil)

        store.cancelPairing()

        #expect(store.connectionError == nil)
        #expect(store.connectionState == .disconnected)
        #expect(store.macConnectionStatus == .unavailable)
    }

    @Test func signOutResetsConnectionStateThroughCoordinator() async throws {
        let router = ConnectionTestRouter()
        let store = signedInStore(router: router)
        let connected = await store.connectPairingURL(try ShellTestFrames.attachURL(for: ShellTestFrames.liveTicket()))
        try #require(connected)

        store.signOut()

        #expect(store.phase == .signIn)
        #expect(store.connectionState == .disconnected)
        #expect(store.connectedHostName.isEmpty)
        #expect(store.pairingCode.isEmpty)
        #expect(store.activeTicket == nil)
        #expect(store.connection.remoteClient == nil)
    }

    // MARK: - Helpers

    private func signedInStore(
        router: any ShellTransportRouter,
        pairedMacStore: (any MobilePairedMacStoring)? = nil
    ) -> MobileShellComposite {
        let runtime = TestShellSyncRuntime(
            transportFactory: ShellRouterTransportFactory(router: router, pusher: ShellEventPusher()),
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite(
            runtime: runtime,
            workspaces: PreviewMobileHost.workspaces,
            pairedMacStore: pairedMacStore
        )
        store.signIn()
        return store
    }

    private func waitUntilAsync(
        _ condition: () async throws -> Bool
    ) async throws {
        for _ in 0..<300 {
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(try await condition())
    }
}

/// Scripted Mac host for connection-lifecycle tests: serves the pairing
/// workspace list (optionally rejecting it as unauthorized) and mints attach
/// tickets for the manual-host flow.
actor ConnectionTestRouter: ShellTransportRouter {
    enum WorkspaceListBehavior {
        case succeed
        case unauthorized
    }

    private let workspaceList: WorkspaceListBehavior
    private let attachTicketRoute: CmxAttachRoute?
    private var requests: [RecordedShellRPCRequest] = []

    init(
        workspaceList: WorkspaceListBehavior = .succeed,
        attachTicketRoute: CmxAttachRoute? = nil
    ) {
        self.workspaceList = workspaceList
        self.attachTicketRoute = attachTicketRoute
    }

    func record(_ request: RecordedShellRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedShellRPCRequest] {
        requests
    }

    func response(for request: RecordedShellRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            switch workspaceList {
            case .succeed:
                return try ShellTestFrames.workspaceListFrame(
                    workspaceID: "live-workspace",
                    title: "Live Workspace",
                    terminalID: "live-terminal"
                )
            case .unauthorized:
                return try ShellTestFrames.errorFrame(code: "unauthorized", message: "unauthorized")
            }
        case "mobile.attach_ticket.create":
            guard let attachTicketRoute else {
                return try ShellTestFrames.errorFrame(code: "method_not_found", message: "unknown method")
            }
            return try ShellTestFrames.attachTicketFrame(route: attachTicketRoute, workspaceID: "live-workspace")
        default:
            return try ShellTestFrames.errorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }
}

/// In-memory ``MobilePairedMacStoring`` fake for connection tests.
actor InMemoryPairedMacStore: MobilePairedMacStoring {
    private var macs: [MobilePairedMac] = []

    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        now: Date
    ) async throws {
        if markActive {
            for index in macs.indices {
                macs[index].isActive = false
            }
        }
        if let index = macs.firstIndex(where: { $0.macDeviceID == macDeviceID }) {
            macs[index].displayName = displayName
            macs[index].routes = routes
            macs[index].lastSeenAt = now
            macs[index].isActive = markActive || macs[index].isActive
            macs[index].stackUserID = stackUserID
        } else {
            macs.append(
                MobilePairedMac(
                    macDeviceID: macDeviceID,
                    displayName: displayName,
                    routes: routes,
                    createdAt: now,
                    lastSeenAt: now,
                    isActive: markActive,
                    stackUserID: stackUserID
                )
            )
        }
    }

    func loadAll(stackUserID: String?) async throws -> [MobilePairedMac] {
        guard let stackUserID else { return macs }
        return macs.filter { $0.stackUserID == stackUserID }
    }

    func activeMac(stackUserID: String?) async throws -> MobilePairedMac? {
        try await loadAll(stackUserID: stackUserID).first(where: \.isActive)
    }

    func setActive(macDeviceID: String) async throws {
        for index in macs.indices {
            macs[index].isActive = macs[index].macDeviceID == macDeviceID
        }
    }

    func remove(macDeviceID: String) async throws {
        macs.removeAll { $0.macDeviceID == macDeviceID }
    }

    func removeAll() async throws {
        macs = []
    }
}
