import CmuxMobileChief
import CmuxMobileFeed
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Security
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

/// A carrier session for the real ``CloudCarrierLink``: each stream is a `daemon` channel of a
/// mock link that answers like a machine's daemon; `drop` ends it as the Rust carrier does
/// (`waitClosed` resolves, new streams are `closed`).
final class FakeDaemonCarrier: CloudCarrierSession, @unchecked Sendable {
    private let daemon: any MacLink
    private let lock = NSLock()
    private var live = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(daemon: any MacLink) { self.daemon = daemon }

    func connect(deadlineMs: UInt32) async throws {}

    func openStream() async throws -> any CloudCarrierByteStream {
        guard lock.withLock({ live }) else { throw LinkError(code: "closed", message: "the session ended") }
        return ChannelStream(channel: try await daemon.openChannel(service: "daemon", args: [:]))
    }

    func isConnected() async -> Bool { lock.withLock { live } }

    func waitClosed() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                guard live else { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func close() async { drop() }

    func drop() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            live = false
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }
}

/// A link channel as a carrier byte stream.
final class ChannelStream: CloudCarrierByteStream, @unchecked Sendable {
    let channel: any LinkChannel
    init(channel: any LinkChannel) { self.channel = channel }
    func send(_ data: Data) async throws { try await channel.send(data) }
    func recv() async -> Data? { try? await channel.receive() }
    func close() async { await channel.close(code: "eof", reason: "") }
}

/// Cloud machine dials: each makes the real ``CloudCarrierLink`` over a ``FakeDaemonCarrier``
/// (answering like a machine's daemon), records what is opened on it, or refuses.
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
        let carrier = FakeDaemonCarrier(daemon: try await inner.dial(endpoint, transport: transport, accessToken: accessToken))
        let link = RecordingLink(CloudCarrierLink(machineID: id, session: carrier))
        lock.withLock {
            links[id, default: []].append(link)
            carriers[id, default: []].append(carrier)
        }
        return link
    }

    private var carriers: [String: [FakeDaemonCarrier]] = [:]
    /// The live carrier of `machineID`'s last dial.
    func lastCarrier(_ machineID: String) -> FakeDaemonCarrier? { lock.withLock { carriers[machineID]?.last } }
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

    /// The carrier drops (the relay or the daemon ended the session): the link reports it at
    /// once, the controller dials a fresh carrier, and the list and terminals bind to it again.
    @Test func aDroppedCarrierIsDialedAgainAndEverythingRebinds() async throws {
        let store = emptyStore()
        let cloud = RecordingCloudDialer()
        let live = coordinator(store: store, cloud: cloud)
        defer { live.stop() }
        await settle { store.macConnection["m1"] == .connected }
        live.showing(macIDs: nil)
        live.applyCloudMachines([machine(.running)])
        await settle { store.macDataPhase(vm) == .live }
        let first = try #require(live.sessions[vm]?.servedLink)
        cloud.lastCarrier(vm)?.drop()
        await settle { cloud.dials(vm) == 2 && store.macDataPhase(vm) == .live && live.sessions[vm]?.servedLink !== first }
        let second = try #require(live.sessions[vm]?.servedLink)
        #expect(second !== first)
        // The list and a terminal read the new carrier.
        #expect(live.sessions[vm]?.workspaces.daemon != nil)
        #expect(await live.terminalScreenText(tabID: "s1", macID: vm) == vm)
    }

    /// Closing a Cloud link releases its terminals' sizes first (while the link is still up),
    /// one close at a time; a re-target while it releases keeps the link (no late close, no redial).
    @Test func closeLinkReleasesFirstAndARetargetWins() async throws {
        let store = emptyStore()
        let cloud = RecordingCloudDialer()
        let live = coordinator(store: store, cloud: cloud)
        defer { live.stop() }
        var releases = 0
        var linkUpWhileReleasing: [Bool] = []
        var gate: CheckedContinuation<Void, Never>?
        live.releaseBeforeClose = { session in
            releases += 1
            linkUpWhileReleasing.append(session.link.target != nil && session.link.phase.isConnected)
            await withCheckedContinuation { gate = $0 }
        }
        await settle { store.macConnection["m1"] == .connected }
        live.showing(macIDs: nil)
        live.applyCloudMachines([machine(.running)])
        await settle { store.macConnection[vm] == .connected }
        let session = try #require(live.sessions[vm])

        // The race: a close starts releasing, the person opens the machine again meanwhile.
        live.closeLink(session)
        live.closeLink(session)
        await settle { gate != nil }
        #expect(releases == 1, "one close at a time")
        live.touch(vm)
        gate?.resume()
        gate = nil
        for _ in 0..<50 { await Task.yield() }
        #expect(session.link.target != nil, "a re-targeted link stays up")
        #expect(session.pendingClose == nil)
        #expect(cloud.dials(vm) == 1, "never closed and dialed again")

        // Not re-targeted: it closes, after the release, with the link up while it released.
        live.closeLink(session)
        await settle { gate != nil }
        gate?.resume()
        await settle { session.link.target == nil }
        #expect(linkUpWhileReleasing == [true, true])
    }

    /// Remove This iPhone from My Macs leaves Cloud machines' links alone (they approved no keys).
    @Test func removeThisPhoneKeepsCloudLinks() async {
        let store = emptyStore()
        let cloud = RecordingCloudDialer()
        let live = coordinator(store: store, cloud: cloud)
        defer { live.stop() }
        await settle { store.macConnection["m1"] == .connected }
        live.showing(macIDs: nil)
        live.applyCloudMachines([machine(.running)])
        await settle { store.macConnection[vm] == .connected }
        await live.removeThisPhoneFromMacs()
        #expect(live.sessions[vm]?.link.target != nil)
        #expect(cloud.dials(vm) == 1)
    }

    /// Two first dials at once make one key, and the Keychain's errors read as they are:
    /// locked retries, anything else (a missing entitlement) stops with a note.
    @Test func theNoiseKeyIsMadeOnceAndKeychainErrorsAreTold() async throws {
        let secrets = MemorySecretStore()
        let made = KeyMakeCounter()
        let user = "user-\(UUID().uuidString)"
        // Eight first dials at once, off the main actor.
        let loads = (0..<8).map { _ in
            Task.detached {
                try? CloudCarrierKey.load(userID: user, store: secrets, newKey: {
                    made.add()
                    return Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                })
            }
        }
        var keys: [Data?] = []
        for load in loads { keys.append(await load.value) }
        #expect(made.value == 1)
        #expect(Set(keys.compactMap(\.self)).count == 1)

        let locked = FailingSecretStore(status: errSecInteractionNotAllowed)
        #expect(throws: LinkError(code: CloudCarrierDialer.keychainLocked, message: "the Keychain is locked until this iPhone is unlocked")) {
            _ = try CloudCarrierKey.load(userID: user, store: locked, newKey: { Data(count: 32) })
        }
        #expect(CloudCarrierDialer.isRetryable(CloudCarrierKey.failure(KeychainSecretStore.Failure(status: errSecInteractionNotAllowed))))
        let missing = FailingSecretStore(status: -34018)
        do {
            _ = try CloudCarrierKey.load(userID: user, store: missing, newKey: { Data(count: 32) })
            Issue.record("a missing entitlement made a key")
        } catch let error as LinkError {
            #expect(error.code == CloudCarrierDialer.keychainUnavailable)
            #expect(CloudCarrierDialer.isPermanent(error))
        }
        #expect(CloudRefusal.note(CloudCarrierDialer.keychainUnavailable, machine: "Build box")
            == "This iPhone's Keychain can't keep the key for Cloud machines.")
    }

    /// The carrier's Noise key: made once per account and kept; the app's sign-out
    /// (`AccountSignOut.signedOut`) removes it, so the next sign-in makes a new one.
    @Test func theNoiseKeyIsStableAndForgottenOnSignOut() throws {
        let secrets = MemorySecretStore()
        var made = 0
        let make = { () -> Data in
            made += 1
            return Data(repeating: UInt8(made), count: 32)
        }
        let user = "user-\(UUID().uuidString)"
        let first = try CloudCarrierKey.load(userID: user, store: secrets, newKey: make)
        let again = try CloudCarrierKey.load(userID: user, store: secrets, newKey: make)
        #expect(first == again && made == 1)
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-cloud-signout-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "cmux-mobile-cloud-signout-\(UUID().uuidString)") ?? .standard
        var signOut = AccountSignOut(snapshots: LiveSnapshotStore(directory: directory.appending(path: "snapshots")), feedStore: FeedStore(items: []),
                                     feedArchive: { FeedArchive(url: directory.appending(path: "feed-\($0).json")) },
                                     readMarks: { FeedReadMarks(url: directory.appending(path: "read-\($0).json")) },
                                     preferences: AccountPreferences(defaults: defaults), discardChiefOutbox: {}, discardKeptChats: {})
        signOut.secrets = secrets
        signOut.signedOut(userID: user, session: nil)
        #expect(try secrets.read(service: DeviceIdentity.defaultService, account: CloudCarrierKey.account(user)) == nil)
        let next = try CloudCarrierKey.load(userID: user, store: secrets, newKey: make)
        #expect(next != first && made == 2)
    }

    /// The service refused even a fresh token for a Cloud machine's dial: its line says to sign
    /// in (not a dead "Signed out"), and Retry dials it on a new session.
    @Test func aSignedOutCloudSessionSaysSoAndRetryDialsAgain() async {
        let store = emptyStore()
        let cloud = RecordingCloudDialer()
        cloud.refuse(vm, LinkError(code: LinkError.unauthorized, message: "401"))
        let live = coordinator(store: store, cloud: cloud)
        defer { live.stop() }
        await settle { store.macConnection["m1"] == .connected }
        live.showing(macIDs: nil)
        live.applyCloudMachines([machine(.running)])
        await settle { live.isCloudRefused(vm) }
        #expect(store.cloudMachines.first?.cloud?.status == .failed)
        #expect(store.cloudMachines.first?.cloud?.note == "Sign in again to open Build box.")
        cloud.refuse(vm, nil)
        live.retryCloud(vm)
        await settle { store.macDataPhase(vm) == .live }
        #expect(!live.isCloudRefused(vm))
    }

    /// No daemon key yet: no more dials until the machine's listing changes.
    @Test func noDaemonKeyWaitsForTheListToChange() async {
        let store = emptyStore()
        let cloud = RecordingCloudDialer()
        cloud.refuse(vm, LinkError(code: CloudCarrierDialer.noDaemonKey, message: "none yet"))
        let live = coordinator(store: store, cloud: cloud)
        defer { live.stop() }
        await settle { store.macConnection["m1"] == .connected }
        live.showing(macIDs: nil)
        live.applyCloudMachines([machine(.running)])
        await settle { live.isCloudRefused(vm) }
        // The same listing read again: still held.
        live.applyCloudMachines([machine(.running)])
        #expect(live.isCloudRefused(vm))
        // The listing changed (it reported in): dialed again.
        cloud.refuse(vm, nil)
        live.applyCloudMachines([MacDevice(cloudMachine: vm, name: "Build box", state: CloudMachineState(status: .running),
                                           lastActiveAt: Date(timeIntervalSince1970: 5_000))])
        await settle { store.macDataPhase(vm) == .live }
        #expect(!live.isCloudRefused(vm))
    }

    /// Cloud machines have their own link cap: they never take a Mac's link, and the one the
    /// person opens last is linked (no dead Connect).
    @Test func cloudMachinesHaveTheirOwnLinkCap() async {
        let store = emptyStore()
        let cloud = RecordingCloudDialer()
        let live = coordinator(store: store, cloud: cloud)
        defer { live.stop() }
        await settle { store.macConnection["m1"] == .connected }
        live.showing(macIDs: nil)
        let ids = (1...5).map { "vm_cap\(String(repeating: "0", count: 16))\($0)" }
        live.applyCloudMachines(ids.map { MacDevice(cloudMachine: $0, name: $0, state: CloudMachineState(status: .running)) })
        await settle { ids.filter { store.macConnection[$0] == .connected }.count == LiveCoordinator.cloudLinkCap }
        #expect(store.macConnection["m1"] == .connected, "the Mac keeps its link")
        let unlinked = ids.first { !live.isLinked(macID: $0) }!
        live.touch(unlinked)
        await settle { store.macConnection[unlinked] == .connected }
        #expect(ids.filter { live.isLinked(macID: $0) }.count == LiveCoordinator.cloudLinkCap)
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
        // The line wakes at once, before the op answers (optimistic).
        #expect(store.cloudMachines.first?.cloud?.status == .starting)
        await settle { ops.all.contains("cloud.machine.start") }
        #expect(ops.all.contains("cloud.machine.start"))
    }

    /// The poll reads every 4 s while something changes, every 15 s once a change has run past
    /// two minutes (a machine stuck provisioning), and every minute otherwise.
    @Test func thePollBacksOffAStuckChange() {
        #expect(LiveCloudWorkspaces.pollInterval(busy: false, busyFor: nil) == .seconds(60))
        #expect(LiveCloudWorkspaces.pollInterval(busy: true, busyFor: .seconds(10)) == .seconds(4))
        #expect(LiveCloudWorkspaces.pollInterval(busy: true, busyFor: .seconds(119)) == .seconds(4))
        #expect(LiveCloudWorkspaces.pollInterval(busy: true, busyFor: .seconds(120)) == .seconds(15))
    }

    /// The Workspaces list reads the machines only (no plan, no snapshots).
    @Test func theListPollReadsMachinesOnly() async {
        let ops = OpsLog()
        ServiceStub.install(host: host) { request in
            if let op = Self.op(request) { ops.add(op) }
            return .init(body: Self.list([("vm_run", "running")]))
        }
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let (live, cloud) = make(store: store, ops: ops)
        defer { live.stop() }
        await cloud.refresh()
        #expect(ops.all == ["cloud.machine.list"])
    }

    /// Start shows the machine waking at once, before the op answers; a second change while one
    /// runs is told, not dropped silently.
    @Test func startWakesAtOnceAndABusyStartIsTold() async {
        ServiceStub.install(host: host) { request in
            switch Self.op(request) {
            case "cloud.machine.list": return .init(body: Self.list([("vm_a", "paused"), ("vm_b", "paused")]))
            case "cloud.machine.start": return .init(body: #"{"value":{"machine":{"id":"vm_a","status":"starting","size":{},"idle_policy":{}}}}"#, held: true)
            default: return .init()
            }
        }
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let (live, cloud) = make(store: store, ops: OpsLog())
        defer { live.stop() }
        var said: [String] = []
        cloud.onRefusal = { said.append($0) }
        await cloud.refresh()
        cloud.start(machineID: "vm_a")
        #expect(store.cloudMachines.first { $0.id == "vm_a" }?.cloud?.status == .starting, "waking before the op answers")
        await settle { cloud.model.busyID == "vm_a" }
        cloud.start(machineID: "vm_b")
        await settle { !said.isEmpty }
        #expect(said == ["Another Cloud machine change is still running. Try again in a moment."])
        ServiceStub.release(host: host)
    }

    /// Retry on a machine its carrier refused dials again, whatever the listing says now.
    @Test func retryOnARefusedMachineDialsWhateverItsListing() async {
        ServiceStub.install(host: host) { request in
            Self.op(request) == "cloud.machine.list" ? .init(body: Self.list([("vm_s", "starting")])) : .init()
        }
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let (live, cloud) = make(store: store, ops: OpsLog())
        defer { live.stop() }
        await cloud.refresh()
        live.cloudRefused("vm_s", LinkError(code: "carrier.handshake", message: "x"))
        #expect(live.isCloudRefused("vm_s"))
        cloud.start(machineID: "vm_s")
        #expect(!live.isCloudRefused("vm_s"))
    }

    /// A list read that fails (offline, a token being refreshed) leaves the machines, their
    /// links and rows as they were.
    @Test func aFailedReadKeepsTheLastList() async {
        let failing = OpsLog()
        ServiceStub.install(host: host) { request in
            guard Self.op(request) == "cloud.machine.list" else { return .init() }
            if failing.all.contains("fail") { return .init(status: 503, body: #"{"error":{"code":"unavailable","message":"x"}}"#) }
            return .init(body: Self.list([("vm_run", "running")]))
        }
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let (live, cloud) = make(store: store, ops: OpsLog())
        defer { live.stop() }
        await cloud.refresh()
        #expect(store.cloudMachines.map(\.id) == ["vm_run"])
        failing.add("fail")
        await cloud.refresh()
        #expect(store.cloudMachines.map(\.id) == ["vm_run"])
        // Only sign-out clears it.
        cloud.stop()
        #expect(store.cloudMachines.isEmpty)
    }

    /// The machine was made; a list read failing meanwhile never reads as a refusal of it: its
    /// pending line stays, nothing is said, and a second machine is not offered.
    @Test func aConcurrentReadFailureKeepsThePendingLine() async {
        let ops = OpsLog()
        ServiceStub.install(host: host) { request in
            let op = Self.op(request)
            if let op { ops.add(op) }
            switch op {
            case "cloud.machine.create":
                return .init(body: #"{"value":{"machine":{"id":"vm_new","name":"Cloud Machine","status":"provisioning","size":{},"idle_policy":{}}}}"#)
            case "cloud.machine.list":
                return ops.all.contains("cloud.machine.create")
                    ? .init(status: 503, body: #"{"error":{"code":"unavailable","message":"x"}}"#) : .init(body: Self.list([]))
            default: return .init()
            }
        }
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let (live, cloud) = make(store: store, ops: ops)
        defer { live.stop() }
        var refusals: [String] = []
        cloud.onRefusal = { refusals.append($0) }
        await cloud.refresh()
        cloud.newCloudWorkspace { _ in }
        await settle { cloud.creations.first?.machineID == "vm_new" }
        #expect(refusals.isEmpty)
        #expect(store.cloudMachines.map(\.id) == ["vm_new"])
        #expect(store.cloudMachines.first?.cloud?.pendingWorkspace == true)
        #expect(!cloud.canCreateMachine)
        cloud.stop()
    }

    /// New Cloud Workspace all the way: the machine is made, runs, its carrier and daemon come
    /// up, and the new workspace on it opens.
    @Test func aNewCloudWorkspaceOpensOnceItsDaemonAnswers() async {
        let ops = OpsLog()
        let made = "vm_new0000000000000001"
        ServiceStub.install(host: host) { request in
            let op = Self.op(request)
            if let op { ops.add(op) }
            switch op {
            case "cloud.machine.create":
                return .init(body: #"{"value":{"machine":{"id":"\#(made)","name":"Cloud Machine","status":"provisioning","size":{},"idle_policy":{}}}}"#)
            case "cloud.machine.list":
                // Running from the second read after the create on.
                let reads = ops.all.split(separator: "cloud.machine.create").last?.filter { $0 == "cloud.machine.list" }.count ?? 0
                guard ops.all.contains("cloud.machine.create") else { return .init(body: Self.list([])) }
                return .init(body: Self.list([(made, reads >= 2 ? "running" : "provisioning")]))
            default: return .init()
            }
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-cloud-\(UUID().uuidString)")
        let snapshots = LiveSnapshotStore(directory: directory)
        snapshots.save(LiveSnapshot(teamID: "t-cloud", teamName: "One", macs: [MacDevice(id: "m1", name: "Studio", isOnline: true)],
                                    linkedMacID: "m1", workspaces: [:]), accountID: userID)
        snapshots.flush()
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let live = LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: PerMacDialer(), cloudDialer: RecordingCloudDialer(),
            feedStore: FeedStore(items: []), snapshots: snapshots)
        defer { live.stop() }
        let model = CloudMachinesModel.scripted(base: URL(string: "https://\(host)")!, session: ServiceStub.session())
        let cloud = LiveCloudWorkspaces(model: model, coordinator: live)
        cloud.busyPoll = .milliseconds(20)
        let creator = WorkspaceCreator(store: store, backend: MultiMacWorkspaceBackend(coordinator: live),
                                       defaults: UserDefaults(suiteName: "cloud-create-\(UUID().uuidString)") ?? .standard)
        cloud.createWorkspace = { creator.create(start: .terminal, macID: $0) }
        var refusals: [String] = []
        cloud.onRefusal = { refusals.append($0) }
        await settle { store.macConnection["m1"] == .connected }
        live.showing(macIDs: nil)
        cloud.start()
        await settle { model.phase == .loaded }
        var opened: [Workspace] = []
        cloud.newCloudWorkspace { opened.append($0) }
        await settle { !opened.isEmpty || !refusals.isEmpty }
        #expect(refusals.isEmpty, "\(refusals)")
        #expect(opened.first?.macID == made)
        #expect(store.macDataPhase(made) == .live)
        #expect(cloud.creations.isEmpty)
        cloud.stop()
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

/// A Keychain that answers every call with `status`.
final class FailingSecretStore: DeviceSecretStore, @unchecked Sendable {
    let status: OSStatus
    init(status: OSStatus) { self.status = status }
    func read(service: String, account: String) throws -> Data? { throw KeychainSecretStore.Failure(status: status) }
    func write(_ data: Data, service: String, account: String) throws { throw KeychainSecretStore.Failure(status: status) }
    func delete(service: String, account: String) {}
}

final class KeyMakeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
