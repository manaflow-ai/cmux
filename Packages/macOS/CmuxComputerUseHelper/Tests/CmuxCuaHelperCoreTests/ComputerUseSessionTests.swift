// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Darwin
import Foundation
import os
import Testing

/// The mode: from the environment the host set, never from a request.
@Suite struct ComputerUseConfigurationTests {
    @Test func askIsTheDefaultAndEveryModeParses() throws {
        #expect(try ComputerUseConfiguration(environment: [:]).mode == .ask)
        #expect(try ComputerUseConfiguration(environment: ["CMUX_COMPUTER_USE_MODE": "standard"]).mode == .standard)
        let bounded = try ComputerUseConfiguration(environment: ["CMUX_COMPUTER_USE_MODE": "bounded",
                                                                 "CMUX_COMPUTER_USE_MANIFEST": "/etc/m.yaml"])
        #expect(bounded.ownerManifestPath == "/etc/m.yaml")
        let unrestricted = try ComputerUseConfiguration(environment: [
            "CMUX_COMPUTER_USE_MODE": "unrestricted", "CUA_DRIVER_PERMISSION_MODE": "unrestricted",
            "CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS": "1",
        ])
        #expect(unrestricted.mode == .unrestricted)
    }

    @Test func invalidConfigurationFailsClosed() {
        #expect(throws: ComputerUseConfiguration.ConfigurationError.unknownMode("yolo")) {
            try ComputerUseConfiguration(environment: ["CMUX_COMPUTER_USE_MODE": "yolo"])
        }
        #expect(throws: ComputerUseConfiguration.ConfigurationError.boundedNeedsManifest) {
            try ComputerUseConfiguration(environment: ["CMUX_COMPUTER_USE_MODE": "bounded"])
        }
        #expect(throws: ComputerUseConfiguration.ConfigurationError.unrestrictedNotAcknowledged) {
            try ComputerUseConfiguration(environment: ["CMUX_COMPUTER_USE_MODE": "unrestricted",
                                                       "CUA_DRIVER_PERMISSION_MODE": "unrestricted"])
        }
    }

    @Test func theDriverCeilingIsTheConfiguredMode() {
        func options(_ mode: ComputerUseMode, _ path: String?) -> String {
            String(decoding: ComputerUseConfiguration(mode: mode, client: "c", machine: "m")
                .driverOptions(compatibilityManifestPath: path), as: UTF8.self)
        }
        #expect(options(.ask, "/t/c.json") == #"{"authorization":{"allowed_modes":["bounded"],"#
            + #""compatibility_capability_manifest_path":"/t/c.json","compatibility_mode":"bounded","#
            + #""max_idle_ttl_seconds":1800,"max_session_ttl_seconds":28800,"unrestricted_acknowledged":false}}"#)
        #expect(options(.standard, nil) == #"{"authorization":{"allowed_modes":["standard"],"#
            + #""compatibility_mode":"standard","max_idle_ttl_seconds":1800,"max_session_ttl_seconds":28800,"#
            + #""unrestricted_acknowledged":false}}"#)
        #expect(options(.unrestricted, nil) == #"{"authorization":{"allowed_modes":["unrestricted"],"#
            + #""compatibility_mode":"unrestricted","max_idle_ttl_seconds":1800,"max_session_ttl_seconds":28800,"#
            + #""unrestricted_acknowledged":true}}"#)
    }
}

/// The `ask` manifest the pinned driver accepts.
@Suite struct CapabilityManifestTests {
    @Test func theManifestListsReviewedToolsTheAppsAndNoDisplay() throws {
        let tools = CapabilityManifest.allowedTools(inventory: SessionFixture.inventory)
        #expect(tools == ["click", "get_window_state", "launch_app", "list_apps", "type_text"],
                "no opaque dispatch, no unreviewed tool, type_text_chars is type_text")
        let manifest = CapabilityManifest(tools: tools, apps: [ApprovalApp(bundleID: "com.apple.Safari", name: "Safari")],
                                          expiresAfterSeconds: 28800, idleTimeoutSeconds: 1800)
        #expect(String(decoding: manifest.data, as: UTF8.self)
            == #"{"allow":{"tools":["click","get_window_state","launch_app","list_apps","type_text"]},"#
            + #""expires_after":"28800s","idle_timeout":"1800s","#
            + #""resources":{"apps":[{"bundle_id":"com.apple.Safari"}],"desktop":{"display":false}},"version":3}"#)
    }

    @Test func idleNeverExceedsWhatIsLeftOfTheLifetime() throws {
        let manifest = CapabilityManifest(tools: ["click"], apps: [], expiresAfterSeconds: 600, idleTimeoutSeconds: 1800)
        let object = try #require(HelperWire.object(manifest.data))
        #expect(object["expires_after"] as? String == "600s")
        #expect(object["idle_timeout"] as? String == "600s")
    }

    @Test func manifestsAreWrittenPrivately() throws {
        let store = try SessionFixture.store()
        defer { try? FileManager.default.removeItem(atPath: store.directory) }
        let path = try store.write(Data("{}".utf8), name: "m.json")
        var info = stat()
        #expect(stat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(stat(store.directory, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(throws: ManifestStore.StoreError.self) { try store.write(Data("{}".utf8), name: "m.json") }
        store.remove(path)
    }
}

/// Upstream sessions per connection, app approvals, and consent last.
@Suite struct ComputerUseSessionTests {
    @Test(.timeLimit(.minutes(1))) func admissionCreatesABoundedSessionWithNoApp() async throws {
        let fixture = try SessionFixture(mode: .ask)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        let created = fixture.driver.created()
        try #require(created.count == 1, "the upstream session exists from admission")
        #expect(created[0].options["mode"] as? String == "bounded")
        #expect(created[0].options["ttl_seconds"] as? Int == 28800)
        #expect(created[0].options["idle_ttl_seconds"] as? Int == 1800)
        #expect((created[0].options["public_session"] as? String)?.hasPrefix("cmux-") == true)
        let manifest = try #require(created[0].manifest)
        #expect((manifest["resources"] as? [String: Any])?["apps"] as? [Any] != nil)
        #expect(((manifest["resources"] as? [String: Any])?["apps"] as? [Any])?.isEmpty == true)
        #expect(((manifest["resources"] as? [String: Any])?["desktop"] as? [String: Any])?["display"] as? Bool == false)
        #expect(manifest["expires_after"] as? String == "28800s")
        #expect(manifest["idle_timeout"] as? String == "1800s")
        #expect(fixture.manifestFiles().isEmpty, "each manifest is removed once the driver read it")
        session.close()
        #expect(created[0].session.destroyed, "closing the connection destroys its session")
    }

    @Test(.timeLimit(.minutes(1))) func aSessionGrantReplacesTheHandle() async throws {
        let fixture = try SessionFixture(mode: .ask)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        let call = Task { try await session.invoke(name: "click", arguments: SessionFixture.textEditClick) }
        let line = try await fixture.host.next()
        let request = try #require(line["request"] as? [String: Any])
        #expect((request["target"] as? [String: Any])?["bundle_id"] as? String == "com.apple.TextEdit",
                "the resolved target, from the window's pid")
        #expect(request["risk"] as? String == "R1")
        #expect(fixture.driver.created()[0].session.invoked.isEmpty, "nothing runs while it asks")
        fixture.answer(line, "session")
        _ = try await call.value
        var created = fixture.driver.created()
        try #require(created.count == 2)
        #expect(created[0].session.destroyed, "the replaced handle is destroyed")
        #expect(created[1].apps == ["com.apple.TextEdit"])
        #expect(created[1].session.invoked == ["click"])
        _ = try await session.invoke(name: "click", arguments: SessionFixture.textEditClick)
        created = fixture.driver.created()
        #expect(created.count == 2, "the grant holds: no new question, no new handle")
        #expect(created[1].session.invoked == ["click", "click"])
        #expect(fixture.host.sent.withLock { $0.count } == 1)
        session.close()
    }

    @Test(.timeLimit(.minutes(1))) func onceRunsOnAOneCallHandle() async throws {
        let fixture = try SessionFixture(mode: .ask)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        let call = Task { try await session.invoke(name: "click", arguments: SessionFixture.textEditClick) }
        fixture.answer(try await fixture.host.next(), "once")
        _ = try await call.value
        let created = fixture.driver.created()
        try #require(created.count == 2)
        #expect(created[1].apps == ["com.apple.TextEdit"])
        #expect(created[1].session.invoked == ["click"])
        #expect(created[1].session.destroyed, "the one-call handle ends with the call")
        #expect(!created[0].session.destroyed, "the session's own handle stays")
        let again = Task { try await session.invoke(name: "click", arguments: SessionFixture.textEditClick) }
        fixture.answer(try await fixture.host.next(), "deny")
        await #expect(throws: AppApprovalRefusal(code: .denied, app: "TextEdit", tool: "click")) {
            try await again.value
        }
        #expect(fixture.driver.created().count == 2, "a denied call never reaches the driver")
        session.close()
    }

    @Test(.timeLimit(.minutes(1))) func neverAllowedAppsAreRefusedWithoutAsking() async throws {
        let fixture = try SessionFixture(mode: .ask)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        await #expect(throws: ToolError.self) {
            try await session.invoke(name: "click", arguments: Data(#"{"pid":100}"#.utf8))
        }
        #expect(fixture.host.sent.withLock { $0.isEmpty }, "Terminal is never asked about")
        session.close()
    }

    @Test(.timeLimit(.minutes(1))) func untargetedCallsRunWithoutAQuestion() async throws {
        let fixture = try SessionFixture(mode: .ask)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        _ = try await session.invoke(name: "list_apps", arguments: Data("{}".utf8))
        #expect(fixture.driver.created()[0].session.invoked.isEmpty, "the worker answers discovery under ask (D21)")
        #expect(fixture.host.sent.withLock { $0.isEmpty })
        session.close()
    }

    @Test(.timeLimit(.minutes(1))) func machineConsentStillRunsLast() async throws {
        let fixture = try SessionFixture(mode: .ask)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        fixture.consent.set(MachineConsentStatus(consentRequired: true, screen: true, control: false))
        let call = Task { try await session.invoke(name: "click", arguments: SessionFixture.textEditClick) }
        fixture.answer(try await fixture.host.next(), "session")
        await #expect(throws: ConsentRefusal.self) { try await call.value }
        #expect(fixture.driver.created().allSatisfy { $0.session.invoked.isEmpty })
        session.close()
    }

    @Test(.timeLimit(.minutes(1))) func grantsLapseAfterThirtyIdleMinutes() async throws {
        let fixture = try SessionFixture(mode: .ask)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        let call = Task { try await session.invoke(name: "click", arguments: SessionFixture.textEditClick) }
        fixture.answer(try await fixture.host.next(), "session")
        _ = try await call.value
        fixture.uptime.withLock { $0 += 31 * 60 }
        let later = Task { try await session.invoke(name: "click", arguments: SessionFixture.textEditClick) }
        let line = try await fixture.host.next()
        #expect(line["type"] as? String == "app_approval", "idle: the session asks again")
        fixture.answer(line, "deny")
        _ = try? await later.value
        session.close()
    }

    @Test(.timeLimit(.minutes(1))) func closingTheConnectionCancelsItsQuestion() async throws {
        let fixture = try SessionFixture(mode: .ask)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        let call = Task { try await session.invoke(name: "click", arguments: SessionFixture.textEditClick) }
        let line = try await fixture.host.next()
        session.close()
        let cancel = try await fixture.host.next()
        #expect(cancel["type"] as? String == "app_approval_cancel")
        #expect(cancel["id"] as? Int == line["id"] as? Int)
        await #expect(throws: AppApprovalRefusal.self) { try await call.value }
        #expect(fixture.driver.created()[0].session.destroyed)
    }

    @Test(.timeLimit(.minutes(1))) func standardModeNeverAsks() async throws {
        let fixture = try SessionFixture(mode: .standard)
        defer { fixture.cleanUp() }
        let session = try fixture.sessions.openSession()
        _ = try await session.invoke(name: "click", arguments: SessionFixture.textEditClick)
        let created = fixture.driver.created()
        #expect(created.count == 1)
        #expect(created[0].options["mode"] as? String == "standard")
        #expect(created[0].options["capability_manifest_path"] == nil)
        #expect(created[0].session.invoked == ["click"])
        #expect(fixture.host.sent.withLock { $0.isEmpty })
        session.close()
    }

    @Test(.timeLimit(.minutes(1))) func eachConnectionHasItsOwnSession() async throws {
        let fixture = try SessionFixture(mode: .ask)
        defer { fixture.cleanUp() }
        let first = try fixture.sessions.openSession()
        let second = try fixture.sessions.openSession()
        let created = fixture.driver.created()
        #expect(created.count == 2)
        #expect(created[0].options["public_session"] as? String != created[1].options["public_session"] as? String)
        first.close()
        #expect(created[0].session.destroyed && !created[1].session.destroyed)
        second.close()
    }

    /// Over the real socket: request fields named `session` or `mode`, in a
    /// call or in `session/hello`, change neither.
    @Test(.timeLimit(.minutes(1))) func noRequestSelectsTheModeOrTheSession() async throws {
        let fixture = try SessionFixture(mode: .ask)
        defer { fixture.cleanUp() }
        let client = try SocketClient(sessions: fixture.sessions)
        let hello = try client.request(["id": 0, "method": "session/hello", "session": "attacker", "mode": "unrestricted",
                                        "params": ["agent": "Claude", "workspace": "api-server", "client": "x",
                                                   "session": "attacker", "mode": "unrestricted"]])
        #expect(hello["ok"] as? Bool == true)
        try client.send(["id": 1, "method": "tools/call", "name": "click", "session": "attacker",
                         "mode": "unrestricted", "permission_mode": "unrestricted",
                         "arguments": ["pid": 102, "window_id": 9001, "session": "attacker"]])
        let line = try await fixture.host.next()
        let request = try #require(line["request"] as? [String: Any])
        let created = fixture.driver.created()
        let public0 = try #require(created.first?.options["public_session"] as? String)
        #expect(request["session"] as? String != "attacker")
        #expect(public0 == "cmux-\(request["session"] as? String ?? "")-1", "the connection's own session")
        #expect(request["agent"] as? String == "Claude", "hello labels the card")
        #expect(created.allSatisfy { $0.options["mode"] as? String == "bounded" })
        fixture.answer(line, "deny")
        let reply = try client.read()
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["code"] as? String == "approval_denied")
        client.close()
    }
}

// MARK: Fakes

final class SessionFixture: Sendable {
    static let inventory = Data(#"""
    [{"name":"click"},{"name":"type_text"},{"name":"type_text_chars"},{"name":"list_apps"},
     {"name":"get_window_state","annotations":{"readOnlyHint":true}},{"name":"launch_app"},
     {"name":"run_script"},{"name":"replay_trajectory"},{"name":"run_steps"},{"name":"some_new_tool"}]
    """#.utf8)
    static let textEditClick = Data(#"{"pid":102,"window_id":9001}"#.utf8)

    let driver: FakeDriver
    let host: AppApprovalBrokerTests.FakeHost
    let consent: MachineConsentTests.ScriptedAuthority
    let uptime: OSAllocatedUnfairLock<TimeInterval>
    let broker: AppApprovalBroker
    let link: UInt64
    let sessions: ComputerUseSessions
    let store: ManifestStore
    let scheduler: AppApprovalBrokerTests.ManualScheduler

    init(mode: ComputerUseMode, ownerManifest: Data? = nil, desktop: FakeDesktop = FakeDesktop()) throws {
        let store = try Self.store()
        let ownerPath = try ownerManifest.map { try store.write($0, name: "owner.json") }
        let driver = FakeDriver()
        let host = AppApprovalBrokerTests.FakeHost()
        let consent = MachineConsentTests.ScriptedAuthority()
        let uptime = OSAllocatedUnfairLock<TimeInterval>(initialState: 1000)
        let scheduler = AppApprovalBrokerTests.ManualScheduler()
        let broker = AppApprovalBroker(client: "com.cmuxterm.app.debug.cu1", machine: "mac-1",
                                       schedule: { scheduler.add($0, $1) })
        self.scheduler = scheduler
        consent.set(MachineConsentStatus(consentRequired: false, screen: false, control: false))
        self.store = store
        self.driver = driver
        self.host = host
        self.consent = consent
        self.uptime = uptime
        self.broker = broker
        link = host.attach(to: broker)
        sessions = ComputerUseSessions(
            driver: driver,
            configuration: ComputerUseConfiguration(mode: mode, ownerManifestPath: ownerPath, client: "c", machine: "m"),
            broker: broker, gate: ConsentGate(authority: consent),
            targetGuard: CuaTargetGuard(policy: CuaTargetPolicy(), resolver: Resolver()), manifests: store,
            desktop: desktop, clock: { uptime.withLock { $0 } })
    }

    static func store() throws -> ManifestStore {
        let root = try #require(PrivateDirectory.userTemporaryRoot())
        return ManifestStore(directory: root + "/cumt-\(UUID().uuidString.prefix(8))")
    }

    func manifestFiles() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: store.directory)) ?? [] }

    func cleanUp() { try? FileManager.default.removeItem(atPath: store.directory) }

    func answer(_ line: [String: Any], _ decision: String) {
        let request = line["request"] as? [String: Any] ?? [:]
        broker.receive(["type": "app_approval", "id": line["id"] ?? 0, "ok": true, "decision": decision,
                        "digest": request["digest"] ?? NSNull(), "via": "mac"], link: link)
    }

    struct Resolver: CuaTargetResolving {
        func app(forPID pid: Int32) async -> CuaTargetIdentity? {
            switch pid {
            case 100: CuaTargetIdentity(bundleID: "com.apple.Terminal", name: "Terminal")
            case 102: CuaTargetIdentity(bundleID: "com.apple.TextEdit", name: "TextEdit")
            case 103: CuaTargetIdentity(bundleID: "com.apple.Safari", name: "Safari")
            case 104: CuaTargetIdentity(bundleID: "com.1password.1password", name: "1Password")
            default: nil
            }
        }

        func app(forWindowID id: UInt32) async -> CuaTargetIdentity? { await app(forPID: id == 9001 ? 102 : 999) }
        func app(named name: String) async -> CuaTargetIdentity? { await app(forPID: name == "TextEdit" ? 102 : 999) }
        func app(forBundleID id: String) async -> CuaTargetIdentity? {
            await app(forPID: id == "com.apple.TextEdit" ? 102 : 999)
        }
    }
}

/// Stands for `CuaDriverRuntime`: records each session's options and the
/// manifest it was given (read at creation, as upstream does).
final class FakeDriver: CuaDriverSessionFactory {
    struct Created: @unchecked Sendable {
        let options: [String: Any]
        let manifest: [String: Any]?
        let session: FakeSession

        /// The bundle ids its manifest lists.
        var apps: [String] {
            ((manifest?["resources"] as? [String: Any])?["apps"] as? [[String: Any]] ?? [])
                .compactMap { $0["bundle_id"] as? String }
        }
    }

    private let log = OSAllocatedUnfairLock<[Created]>(uncheckedState: [])

    func created() -> [Created] { log.withLockUnchecked { $0 } }

    func inventory() throws -> Data { SessionFixture.inventory }

    func createSession(options: Data) throws -> any CuaDriverSessionInvoking {
        let parsed = try #require(HelperWire.object(options))
        let manifest = try (parsed["capability_manifest_path"] as? String).map { path in
            try #require(HelperWire.object(try Data(contentsOf: URL(fileURLWithPath: path))))
        }
        let session = FakeSession()
        log.withLockUnchecked { $0.append(Created(options: parsed, manifest: manifest, session: session)) }
        return session
    }
}

final class FakeSession: CuaDriverSessionInvoking {
    private let state = OSAllocatedUnfairLock(initialState: (invoked: [String](), destroyed: false))
    var invoked: [String] { state.withLock { $0.invoked } }
    var destroyed: Bool { state.withLock { $0.destroyed } }

    func invoke(name: String, arguments: Data) async throws -> Data {
        try state.withLock { state in
            guard !state.destroyed else { throw ToolError("destroyed") }
            state.invoked.append(name)
        }
        return Data("{}".utf8)
    }

    func destroy() { state.withLock { $0.destroyed = true } }
}

/// An admitted bridge connection to `HelperSocketServer.serve` with real sessions.
final class SocketClient: @unchecked Sendable {
    private let descriptor: Int32
    private var buffer = HelperWire.LineBuffer()
    private var pending: [Data] = []

    init(sessions: any AgentSessionProviding) throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        descriptor = descriptors[0]
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        try #require(setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
        let daemon = ProcessStamp(pid: 10, startSeconds: 1, startMicroseconds: 0)
        let secret = Data([1, 2, 3])
        let admission = AdmissionState()
        admission.configure(AdmissionConfig(helperUID: geteuid(), acpmuxCDHashes: [Data([1])],
                                            acpmuxRequirement: nil, acpmuxDaemons: [daemon], secret: secret))
        let server = HelperSocketServer(path: "unused", admission: admission,
                                        inspector: MachineConsentTests.Inspector(daemon: daemon),
                                        sessions: sessions, consent: UnavailableConsent())
        let serverDescriptor = descriptors[1]
        Thread { server.serve(serverDescriptor) }.start()
        try send(["secret": HelperWire.hex(secret)])
        let admitted = try read()
        #expect(admitted["ok"] as? Bool == true)
        #expect((admitted["capabilities"] as? [String])?.contains("app-approvals-v1") == true)
    }

    deinit { Darwin.close(descriptor) }

    func close() { shutdown(descriptor, SHUT_RDWR) }

    func send(_ fields: [String: Any]) throws {
        let line = HelperWire.line(fields)
        try #require(line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) } == line.count)
    }

    func request(_ fields: [String: Any]) throws -> [String: Any] {
        try send(fields)
        return try read()
    }

    func read() throws -> [String: Any] {
        while pending.isEmpty {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            try #require(count > 0, "the helper must answer")
            let lines = buffer.append(Data(chunk.prefix(count)))
            pending += try #require(lines)
        }
        return try #require(HelperWire.object(pending.removeFirst()))
    }
}
