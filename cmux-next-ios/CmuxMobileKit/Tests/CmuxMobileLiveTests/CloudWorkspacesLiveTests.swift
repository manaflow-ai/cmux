import CmuxMobileChief
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A link that records the services opened on it (the Cloud carrier must see `daemon` only).
final class RecordingLink: MacLink, @unchecked Sendable {
    private let inner: any MacLink
    private let lock = NSLock()
    private var opened: [String] = []
    var transport: CmuxMobileTransport.TransportKind { inner.transport }
    var states: AsyncStream<LinkState> { inner.states }
    var connectedPath: LinkPathKind? { inner.connectedPath }
    var services: [String] { lock.withLock { opened } }

    init(_ inner: any MacLink) { self.inner = inner }

    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        lock.withLock { opened.append(service) }
        return try await inner.openChannel(service: service, args: args)
    }

    func openInputChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        lock.withLock { opened.append(service) }
        return try await inner.openInputChannel(service: service, args: args)
    }

    func ping() async throws -> UInt32 { try await inner.ping() }
    func close() async { await inner.close() }
}

/// Cloud machine dials: each answers like a Mac's daemon, records what it opens, or refuses.
final class RecordingCloudDialer: MacLinkDialer, @unchecked Sendable {
    private let inner = PerMacDialer()
    private let lock = NSLock()
    private var links: [String: [RecordingLink]] = [:]
    private var refusals: [String: LinkError] = [:]
    private var transports: [CmuxMobileTransport.TransportKind] = []

    func refuse(_ machineID: String, _ error: LinkError?) { lock.withLock { refusals[machineID] = error } }
    func dials(_ machineID: String) -> Int { lock.withLock { (links[machineID]?.count ?? 0) + (refused[machineID] ?? 0) } }
    func services(_ machineID: String) -> [String] { lock.withLock { links[machineID]?.flatMap(\.services) ?? [] } }
    var dialedTransports: [CmuxMobileTransport.TransportKind] { lock.withLock { transports } }
    private var refused: [String: Int] = [:]

    func dial(_ endpoint: LinkEndpoint, transport: CmuxMobileTransport.TransportKind, accessToken: String) async throws -> any MacLink {
        let id = endpoint.macDeviceID
        if let error = lock.withLock({ () -> LinkError? in
            transports.append(transport)
            guard let error = refusals[id] else { return nil }
            refused[id, default: 0] += 1
            return error
        }) { throw error }
        let link = RecordingLink(try await inner.dial(endpoint, transport: transport, accessToken: accessToken))
        lock.withLock { links[id, default: []].append(link) }
        return link
    }
}

// The coordinator is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
/// Every machine is a daemon (plans/cmux-next/cloud-ios.md §3.1): a running Cloud machine is one
/// more session whose link is its carrier. Its workspaces join the store like a Mac's; nothing
/// but `daemon` is opened on it; it never joins the team's Macs; a refusal no redial fixes stops
/// the dials and says why.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct CloudWorkspacesLiveTests {
    let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
    let userID = "user-\(UUID().uuidString)"
    let vm = "vm_aaaaaaaaaaaaaaaaaaaa"

    func coordinator(store: AppStore, cloud: RecordingCloudDialer) -> LiveCoordinator {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-cloud-\(UUID().uuidString)")
        let snapshots = LiveSnapshotStore(directory: directory)
        snapshots.save(LiveSnapshot(teamID: "t-cloud", teamName: "One", macs: [MacDevice(id: "m1", name: "Studio", isOnline: true)],
                                    linkedMacID: "m1", workspaces: ["m1": .init(workspaces: [], savedAt: Date(timeIntervalSince1970: 1_000))]),
                       accountID: userID)
        snapshots.flush()
        return LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: PerMacDialer(), cloudDialer: cloud,
            feedStore: FeedStore(items: []), snapshots: snapshots
        )
    }

    func emptyStore() -> AppStore {
        AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
    }

    func settle(_ done: () -> Bool) async {
        while !done(), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) } // test: polls the condition
    }

    func drain() async {
        for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(2)) }
    }

    func machine(_ status: CloudMachineState.Status) -> MacDevice {
        MacDevice(cloudMachine: vm, name: "Build box", state: CloudMachineState(status: status))
    }

    @Test func aRunningCloudMachineServesItsWorkspacesOverTheCarrierOnly() async {
        let store = emptyStore()
        let cloud = RecordingCloudDialer()
        let live = coordinator(store: store, cloud: cloud)
        defer { live.stop() }
        await settle { store.macConnection["m1"] == .connected }
        live.showing(macIDs: nil)
        live.applyCloudMachines([machine(.running)])
        await settle { store.macDataPhase(vm) == .live }
        #expect(store.workspaces.contains { $0.macID == vm })
        #expect(store.macConnection[vm] == .connected)
        // Never one of the team's Macs (Devices, pairing, presence).
        #expect(store.activeTeam?.macs.map(\.id) == ["m1"])
        #expect(store.cloudMachines.map(\.id) == [vm])
        #expect(live.isCloud(macID: vm))
        await drain()
        // No pairing, version, acpmux, Mac Feed or Chief on a Cloud machine's carrier.
        let services = Set(cloud.services(vm))
        #expect(services == ["daemon"], "opened \(cloud.services(vm))")
        #expect(cloud.dialedTransports.allSatisfy { $0 == .cloudCarrier })
        // A terminal of the Cloud machine opens on its own carrier.
        #expect(await live.terminalScreenText(tabID: "s1", macID: vm) == vm)
        #expect(Set(cloud.services(vm)) == ["daemon"])
        // Settings → Connection changes Mac links only.
        live.setTransport(.webRTC)
        #expect(live.sessions[vm]?.link.transport == .cloudCarrier)
        #expect(live.sessions["m1"]?.link.transport == .webRTC)
        // Choosing it in the filter opens its link; it never takes the focus (banner, Chief).
        live.select(macID: vm)
        #expect(live.focusedMacID == "m1")
    }

    @Test func pausedAndStartingMachinesAreNotDialed() async {
        let store = emptyStore()
        let cloud = RecordingCloudDialer()
        let live = coordinator(store: store, cloud: cloud)
        defer { live.stop() }
        await settle { store.macConnection["m1"] == .connected }
        live.showing(macIDs: nil)
        for status in [CloudMachineState.Status.paused, .starting, .provisioning, .failed, .pausing] {
            live.applyCloudMachines([machine(status)])
            await drain()
            #expect(cloud.dials(vm) == 0, "\(status)")
        }
        // It starts: now it is dialed; it pauses again: its link closes, its rows stay as last known.
        live.applyCloudMachines([machine(.running)])
        await settle { store.macDataPhase(vm) == .live }
        live.applyCloudMachines([machine(.paused)])
        await drain()
        #expect(live.sessions[vm] == nil)
        #expect(store.workspaces.contains { $0.macID == vm })
        // Gone from the list (deleted): its rows go too.
        live.applyCloudMachines([])
        #expect(!store.workspaces.contains { $0.macID == vm })
        #expect(store.cloudMachines.isEmpty)
    }

    @Test func aHandshakeRefusalStopsTheDialsAndSaysWhy() async {
        let store = emptyStore()
        let cloud = RecordingCloudDialer()
        cloud.refuse(vm, LinkError(code: "carrier.handshake", message: "daemon key mismatch"))
        let live = coordinator(store: store, cloud: cloud)
        defer { live.stop() }
        var refusals: [String] = []
        live.onCloudRefusal = { _, code in refusals.append(code) }
        await settle { store.macConnection["m1"] == .connected }
        live.showing(macIDs: nil)
        live.applyCloudMachines([machine(.running)])
        await settle { live.isCloudRefused(vm) }
        #expect(refusals == ["carrier.handshake"])
        #expect(store.cloudMachines.first?.cloud?.status == .failed)
        #expect(store.cloudMachines.first?.cloud?.note?.contains("Build box") == true)
        let dials = cloud.dials(vm)
        await drain()
        #expect(cloud.dials(vm) == dials, "no redial after a handshake refusal")
        // A list read that still says running keeps it refused (only Retry dials again).
        live.applyCloudMachines([machine(.running)])
        await drain()
        #expect(live.isCloudRefused(vm))
        // Retry: the daemon is back to the pinned one.
        cloud.refuse(vm, nil)
        live.retryCloud(vm)
        await settle { store.macDataPhase(vm) == .live }
        #expect(!live.isCloudRefused(vm))
        #expect(store.cloudMachines.first?.cloud?.status == .running)
    }

    @Test func aPausedRefusalClearsWithTheNextList() async {
        let store = emptyStore()
        let cloud = RecordingCloudDialer()
        cloud.refuse(vm, LinkError(code: "cloud.machine.paused", message: "paused"))
        let live = coordinator(store: store, cloud: cloud)
        defer { live.stop() }
        await settle { store.macConnection["m1"] == .connected }
        live.showing(macIDs: nil)
        live.applyCloudMachines([machine(.running)])
        await settle { live.isCloudRefused(vm) }
        live.applyCloudMachines([machine(.paused)])
        #expect(!live.isCloudRefused(vm))
        #expect(store.cloudMachines.first?.cloud?.status == .paused)
    }

    /// The carrier's Noise key: made once per account and kept; sign-out removes it.
    @Test func theNoiseKeyIsStableAndForgottenOnSignOut() throws {
        let secrets = MemorySecretStore()
        var made = 0
        let make = { () -> Data in
            made += 1
            return Data(repeating: UInt8(made), count: 32)
        }
        let first = try CloudCarrierKey.load(userID: "u", store: secrets, newKey: make)
        let again = try CloudCarrierKey.load(userID: "u", store: secrets, newKey: make)
        #expect(first == again && made == 1)
        CloudCarrierKey.forget(userID: "u", store: secrets)
        let next = try CloudCarrierKey.load(userID: "u", store: secrets, newKey: make)
        #expect(next != first && made == 2)
    }
}

/// New Cloud Workspace and Start against a scripted Cloud service.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct LiveCloudWorkspacesTests {
    let host = "cloud-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
    let userID = "user-\(UUID().uuidString)"

    nonisolated static func list(_ machines: [(String, String)]) -> String {
        let items = machines.map { #"{"id":"\#($0.0)","name":"\#($0.0)","status":"\#($0.1)","size":{},"idle_policy":{"idle_seconds":0}}"# }
        return #"{"value":{"machines":[\#(items.joined(separator: ","))],"next_cursor":null}}"#
    }

    /// The op of a `/v1/ops` or `/v1/read` body.
    nonisolated static func op(_ request: URLRequest) -> String? {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            body = data
        }
        return body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["op"] as? String
    }

    func make(store: AppStore, ops: OpsLog) -> (LiveCoordinator, LiveCloudWorkspaces) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-cloud-\(UUID().uuidString)")
        let live = LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: PerMacDialer(), cloudDialer: RecordingCloudDialer(),
            feedStore: FeedStore(items: []), snapshots: LiveSnapshotStore(directory: directory))
        let model = CloudMachinesModel.scripted(base: URL(string: "https://\(host)")!, session: ServiceStub.session())
        let cloud = LiveCloudWorkspaces(model: model, coordinator: live)
        _ = ops
        return (live, cloud)
    }

    final class OpsLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ op: String) { lock.withLock { items.append(op) } }
        var all: [String] { lock.withLock { items } }
    }

    func settle(_ done: () -> Bool) async {
        while !done(), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) } // test: polls the condition
    }

    @Test func theListBecomesCloudMachinesOnTheStore() async {
        let ops = OpsLog()
        ServiceStub.install(host: host) { request in
            if let op = Self.op(request) { ops.add(op) }
            return Self.op(request) == "cloud.machine.list" ? .init(body: Self.list([("vm_run", "running"), ("vm_p", "paused")])) : .init()
        }
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let (live, cloud) = make(store: store, ops: ops)
        defer { live.stop() }
        await cloud.refresh()
        #expect(store.cloudMachines.map(\.id) == ["vm_run", "vm_p"])
        #expect(store.cloudMachines.map(\.isOnline) == [true, false])
        #expect(store.teams.flatMap(\.macs).isEmpty)
    }

    @Test func cloudTurnedOffListsNothing() async {
        ServiceStub.install(host: host) { request in
            Self.op(request) == "cloud.machine.list"
                ? .init(status: 403, body: #"{"error":{"code":"feature.disabled","message":"off"}}"#) : .init()
        }
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let (live, cloud) = make(store: store, ops: OpsLog())
        defer { live.stop() }
        await cloud.refresh()
        #expect(store.cloudMachines.isEmpty)
        #expect(!cloud.canCreateMachine)
    }

    @Test func startIsTheAccountsOwnOp() async {
        let ops = OpsLog()
        ServiceStub.install(host: host) { request in
            let op = Self.op(request)
            if let op { ops.add(op) }
            switch op {
            case "cloud.machine.list": return .init(body: Self.list([("vm_p", ops.all.contains("cloud.machine.start") ? "starting" : "paused")]))
            case "cloud.machine.start": return .init(body: #"{"value":{"machine":{"id":"vm_p","status":"starting","size":{},"idle_policy":{}}}}"#)
            default: return .init()
            }
        }
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let (live, cloud) = make(store: store, ops: ops)
        defer { live.stop() }
        await cloud.refresh()
        #expect(store.cloudMachines.first?.cloud?.status == .paused)
        cloud.start(machineID: "vm_p")
        await settle { store.cloudMachines.first?.cloud?.status == .starting }
        #expect(ops.all.contains("cloud.machine.start"))
    }

    /// New Cloud Workspace shows its pending line at once; a refusal takes it away and says why.
    @Test func aRefusedNewCloudWorkspaceRollsBack() async {
        ServiceStub.install(host: host) { request in
            switch Self.op(request) {
            case "cloud.machine.list": return .init(body: Self.list([]))
            case "cloud.machine.create": return .init(status: 402, body: #"{"error":{"code":"cloud.quota.exceeded","message":"quota"}}"#)
            default: return .init()
            }
        }
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let (live, cloud) = make(store: store, ops: OpsLog())
        defer { live.stop() }
        var refusals: [String] = []
        cloud.onRefusal = { refusals.append($0) }
        await cloud.refresh()
        #expect(cloud.canCreateMachine)
        var opened: [Workspace] = []
        cloud.newCloudWorkspace { opened.append($0) }
        // At once: one pending line, "Starting Cloud Machine…".
        #expect(store.cloudMachines.count == 1)
        #expect(store.cloudMachines.first?.cloud?.pendingWorkspace == true)
        #expect(store.cloudMachines.first?.name == LiveCloudWorkspaces.newMachineName)
        #expect(!cloud.canCreateMachine)
        await settle { !refusals.isEmpty }
        #expect(refusals == ["You're at your plan's machine limit. Pause or delete one first."])
        #expect(store.cloudMachines.isEmpty)
        #expect(cloud.creations.isEmpty)
        #expect(opened.isEmpty)
        // The page's own alert does not show the same refusal again.
        #expect(cloud.model.failure == nil)
    }
}
#endif
