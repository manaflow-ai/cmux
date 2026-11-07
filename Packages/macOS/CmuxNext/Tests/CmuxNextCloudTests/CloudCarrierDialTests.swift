@testable import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// The carrier children the app spawns (design/cloud-carrier.md): one `cmux carrier serve` per Cloud
/// session, whose socket every client of the machine's daemon uses, and `cmux carrier dial --service
/// desktop` per desktop viewer, with the platform origin, the access token and the machine's team in
/// their environment.
@Suite struct CloudCarrierDialTests {
    @Test(arguments: [CloudCarrierDial.Service.mux, .desktop]) func theDialArgvNamesTheMachineServiceAndDeadline(service: CloudCarrierDial.Service) throws {
        let dial = try #require(CloudCarrierDial(machine: "vm_abc123", service: service))
        #expect(dial.arguments == ["carrier", "dial", "--machine", "vm_abc123", "--service", service.rawValue, "--deadline-ms", "180000"])
        #expect(CloudCarrierDial(machine: "", service: service) == nil)
        #expect(CloudCarrierDial(machine: "vm 1; rm -rf /", service: service) == nil)
    }

    @Test func theServeArgvNamesTheMachineAndSocket() throws {
        let dial = try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))
        #expect(dial.serveArguments(socket: "/tmp/x/cmux-link-0123456789ab.sock")
            == ["carrier", "serve", "--machine", "vm_abc123", "--socket", "/tmp/x/cmux-link-0123456789ab.sock"])
    }

    @Test func theServeLinesAreTheReadyLineAndRefusals() {
        #expect(CloudCarrierDial.serveLine(#"{"ok":true,"socket":"/tmp/a.sock","route":"carrier"}"#) == .ready(socket: "/tmp/a.sock"))
        #expect(CloudCarrierDial.serveLine(#"{"ok":false,"error_code":"ticket","route":"carrier"}"#) == .refused(code: "ticket", detail: nil))
        #expect(CloudCarrierDial.serveLine(#"{"ok":false,"error_code":"socket","error_detail":"in use"}"#) == .refused(code: "socket", detail: "in use"))
        #expect(CloudCarrierDial.serveLine(#"{"ok":true,"route":"carrier","vmk":"owner"}"#) == .connected(vmk: "owner"))
        #expect(CloudCarrierDial.serveLine(#"{"ok":true,"route":"carrier"}"#) == .connected(vmk: nil))
        #expect(CloudCarrierDial.serveLine("carrier: listening") == nil)
    }

    /// A refused connection's step reads as the sidebar's existing link wording.
    @Test func aRefusedStepHasItsLinkWording() {
        #expect(CloudCarrierDial.linkError(code: "relay", detail: nil) == .disconnected(reason: "relay"))
        #expect(CloudCarrierDial.linkError(code: "parked_timeout", detail: nil) == .notUp(state: "parked_timeout"))
        #expect(CloudCarrierDial.linkError(code: "ticket", detail: nil) == .failed(code: "ticket", message: ""))
        #expect(CloudCarrierDial.linkError(code: "handshake", detail: "pin") == .failed(code: "handshake", message: "handshake: pin"))
    }

    @Test func theTokenLineIsOneJSONObject() throws {
        let object = try JSONSerialization.jsonObject(with: Data(CloudCarrierDial.tokenLine("t-\"9").utf8)) as? [String: String]
        #expect(object == ["access_token": "t-\"9"])
    }

    @Test func theEnvironmentCarriesTheCredentialAndTheTeamWhenSet() throws {
        let platform = try #require(URL(string: "https://platform.example"))
        let base = ["CMUX_CLOUD_API_URL": "https://platform.example", "CMUX_CLOUD_ACCESS_TOKEN": "t-1"]
        #expect(CloudCarrierDial.environment(platform: platform, accessToken: "t-1", team: nil) == base)
        #expect(CloudCarrierDial.environment(platform: platform, accessToken: "t-1", team: "") == base)
        #expect(CloudCarrierDial.environment(platform: platform, accessToken: "t-1", team: "team_0123456789abcdef0123")
            == base.merging(["CMUX_CLOUD_TEAM": "team_0123456789abcdef0123"]) { $1 })
    }

    /// Every carrier child writes `carrier/connect.log` under the build's own daemon state directory.
    @Test func theEnvironmentCarriesTheDaemonStateDirectory() throws {
        let platform = try #require(URL(string: "https://platform.example"))
        let state = URL(fileURLWithPath: "/Users/me/Library/Application Support/cmux/tags/dev/tui", isDirectory: true)
        #expect(CloudCarrierDial.environment(platform: platform, accessToken: "t-1", team: nil, stateDirectory: state)["CMUX_TUI_STATE_DIR"] == state.path)
        #expect(CloudCarrierDial.environment(platform: platform, accessToken: "t-1", team: nil, stateDirectory: nil)["CMUX_TUI_STATE_DIR"] == nil)
    }

    /// The machine's team comes from its cmux-next record (`team`), the one `cloud.machine.list` answers.
    @Test func theRecordNamesTheMachinesTeam() throws {
        func record(_ json: String) throws -> CloudMachine? {
            CloudMachine(next: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        }
        #expect(try record(#"{"id":"vm_abc123","status":"running","team":"team_0123456789abcdef0123","desktop":true}"#)?.team == "team_0123456789abcdef0123")
        #expect(try record(#"{"id":"vm_abc123","status":"running"}"#)?.team == nil)
    }

    /// The desktop dial's bridge waits for the answer as long as the dial's 180 s deadline plus 2 s.
    @Test func theDialBridgeWaitsOutTheDeadline() throws {
        let dial = try #require(CloudCarrierDial(machine: "vm_abc123", service: .desktop))
        #expect(dial.bridge(cli: URL(fileURLWithPath: "/x/cmux-tui"), environment: [:]).replyTimeoutMs == 182_000)
    }

    /// The desktop dial runs `carrier dial` with the credential in its environment: a stand-in answers the
    /// dial line on stderr and echoes its argv and the three variables as the stream.
    @Test func theDesktopDialRunsWithTheCredential() async throws {
        let cli = try Self.standIn("printf '{\"ok\":true,\"path_state\":\"relay\",\"route\":\"carrier\"}\\n' >&2\nprintf '%s ' \"$@\" \"$CMUX_CLOUD_API_URL\" \"$CMUX_CLOUD_ACCESS_TOKEN\" \"$CMUX_CLOUD_TEAM\"\n")
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .desktop))) {
            ["CMUX_CLOUD_API_URL": "https://p", "CMUX_CLOUD_ACCESS_TOKEN": "t-1", "CMUX_CLOUD_TEAM": "team_x"]
        }
        let stream = try await connector.open()
        var bytes = Data()
        while let chunk = await stream.read() { bytes.append(chunk) }
        stream.close()
        #expect(String(decoding: bytes, as: UTF8.self) == "carrier dial --machine vm_abc123 --service desktop --deadline-ms 180000 https://p t-1 team_x ")
    }

    /// The session's link is the serve child's socket: the ready line hands it over, a later connect gives
    /// the same child a fresh token on stdin, closing stdin stops it, and the next starts after it exited.
    @Test func theServeSocketIsTheLinksSocket() async throws {
        let cli = try Self.standIn("d=$(dirname \"$0\")\necho \"$CMUX_CLOUD_ACCESS_TOKEN\" >> \"$d/launches\"\nprintf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\nwhile read -r l; do echo \"$l\" >> \"$d/stdin\"; done\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("cmux-link-0123456789ab.sock").path
        let tokens = Counter()
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) {
            ["CMUX_CLOUD_API_URL": "https://p", "CMUX_CLOUD_ACCESS_TOKEN": "t-\(await tokens.next())"]
        }
        let serve = CloudCarrierServe(connector: connector, socket: socket) { _ in }
        let link = CloudLinkSession(key: CloudLinkKey(machine: "vm_abc123"), resolver: CloudCarrierResolver(serve: serve) { .owner })
        let ticket = try await link.connect(origin: .user)
        #expect(ticket.socket.path == socket)
        #expect(await link.currentSocket == socket)
        #expect(await link.ownerLink != nil)
        _ = try await link.connect(origin: .user)
        await link.close()
        #expect(try await serve.socketPath() == socket)
        await serve.stop()
        #expect(try String(contentsOf: folder.appendingPathComponent("launches"), encoding: .utf8) == "t-1\nt-3\n")
        #expect(try String(contentsOf: folder.appendingPathComponent("stdin"), encoding: .utf8) == #"{"access_token":"t-2"}"# + "\n")
    }

    /// After the ready line, a refused connection's line ends the link with its step.
    @Test func aRefusedConnectionEndsTheLinkWithItsStep() async throws {
        let cli = try Self.standIn("printf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\nprintf '{\"ok\":false,\"error_code\":\"parked_timeout\",\"route\":\"carrier\"}\\n' >&2\ncat >/dev/null\n")
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) { [:] }
        let serve = CloudCarrierServe(connector: connector, socket: "/tmp/cmux-link-0123456789ab.sock") { _ in }
        let link = CloudLinkSession(key: CloudLinkKey(machine: "vm_abc123"), resolver: CloudCarrierResolver(serve: serve) { .owner })
        let ticket = try await link.connect(origin: .user)
        let deadline = ContinuousClock.now + .seconds(5)
        while await serve.refusal == nil, ContinuousClock.now < deadline { await Task.yield() }
        _ = try await link.endpoint(ticket)
        await #expect(throws: CloudLinkError.notUp(state: "parked_timeout")) { _ = try await link.endpoint(ticket) }
        await link.close()
    }

    /// A socket another serve holds (its `socket` refusal, or a usage exit 64) is a clear failure.
    @Test(arguments: ["printf '{\"ok\":false,\"error_code\":\"socket\"}\\n' >&2\nexit 6\n", "exit 64\n"])
    func aTakenSocketIsAClearFailure(body: String) async throws {
        let cli = try Self.standIn(body)
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) { [:] }
        let serve = CloudCarrierServe(connector: connector, socket: "/tmp/mine.sock") { _ in }
        await #expect(throws: CloudLinkError.failed(code: "socket", message: "another cmux is serving this machine's connection socket")) {
            _ = try await serve.socketPath()
        }
    }

    /// A child that serves another socket than the one asked for is refused.
    @Test func aServeOnAnotherSocketIsRefused() async throws {
        let cli = try Self.standIn("printf '{\"ok\":true,\"socket\":\"/tmp/elsewhere.sock\",\"route\":\"carrier\"}\\n' >&2\ncat >/dev/null\n")
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) { [:] }
        let serve = CloudCarrierServe(connector: connector, socket: "/tmp/mine.sock") { _ in }
        await #expect(throws: CloudLinkError.invalidAnswer("served another socket")) { _ = try await serve.socketPath() }
    }

    /// Ownership is the latest connected line's `vmk`; the record's creator rule only until one arrives.
    @Test func theGrantsVmkOwnsTheLinkElseTheRecord() async throws {
        #expect(CloudCallerOwnership(vmk: "owner") == .owner)
        #expect(CloudCallerOwnership(vmk: "team") == .team)
        #expect(CloudCallerOwnership(vmk: nil) == nil)
        #expect(CloudCallerOwnership(vmk: "admin") == nil)
        let cli = try Self.standIn("printf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\nread -r l\nprintf '{\"ok\":true,\"route\":\"carrier\",\"vmk\":\"team\"}\\n' >&2\nprintf '{\"ok\":true,\"route\":\"carrier\"}\\n' >&2\ncat >/dev/null\n")
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) {
            ["CMUX_CLOUD_ACCESS_TOKEN": "t"]
        }
        let serve = CloudCarrierServe(connector: connector, socket: "/tmp/cmux-link-0123456789ab.sock") { _ in }
        let link = CloudLinkSession(key: CloudLinkKey(machine: "vm_abc123"), resolver: CloudCarrierResolver(serve: serve) { .owner })
        // No connected line yet: the record says owner.
        _ = try await link.connect(origin: .user)
        #expect(await link.callerOwnership == .owner)
        // The second connect's token line lets the stand-in report a team grant, then one with no vmk.
        _ = try await link.connect(origin: .user)
        let deadline = ContinuousClock.now + .seconds(5)
        while await serve.vmk == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await serve.vmk == "team")
        _ = try await link.connect(origin: .user)
        #expect(await link.callerOwnership == .team)
        await link.close()
    }

    @Test func theRecordsCreatorOwnsTheMachine() {
        #expect(CloudCallerOwnership(creator: "u1", caller: "u1") == .owner)
        #expect(CloudCallerOwnership(creator: "u1", caller: "u2") == .team)
        #expect(CloudCallerOwnership(creator: nil, caller: "u1") == .unknown)
        #expect(CloudCallerOwnership(creator: "u1", caller: nil) == .unknown)
    }

    private actor Counter {
        private var value = 0
        func next() -> Int { value += 1; return value }
    }

    private static func standIn(_ body: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ccd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = folder.appendingPathComponent("cmux-tui")
        try ("#!/bin/sh\n" + body).write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return cli
    }
}
