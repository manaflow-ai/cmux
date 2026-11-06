import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// The carrier dial both Cloud routes spawn (design/cloud-carrier.md): `cmux carrier dial --service mux`
/// for each daemon connection of a Cloud session, `--service desktop` for the desktop viewer, with the
/// platform origin, the access token and the machine's team in its environment.
@Suite struct CloudCarrierDialTests {
    @Test(arguments: [CloudCarrierDial.Service.mux, .desktop]) func theArgvNamesTheMachineServiceAndDeadline(service: CloudCarrierDial.Service) throws {
        let dial = try #require(CloudCarrierDial(machine: "vm_abc123", service: service))
        #expect(dial.arguments == ["carrier", "dial", "--machine", "vm_abc123", "--service", service.rawValue, "--deadline-ms", "180000"])
        #expect(CloudCarrierDial(machine: "", service: service) == nil)
        #expect(CloudCarrierDial(machine: "vm 1; rm -rf /", service: service) == nil)
    }

    @Test func theEnvironmentCarriesTheCredentialAndTheTeamWhenSet() throws {
        let platform = try #require(URL(string: "https://platform.example"))
        let base = ["CMUX_CLOUD_API_URL": "https://platform.example", "CMUX_CLOUD_ACCESS_TOKEN": "t-1"]
        #expect(CloudCarrierDial.environment(platform: platform, accessToken: "t-1", team: nil) == base)
        #expect(CloudCarrierDial.environment(platform: platform, accessToken: "t-1", team: "") == base)
        #expect(CloudCarrierDial.environment(platform: platform, accessToken: "t-1", team: "team_0123456789abcdef0123")
            == base.merging(["CMUX_CLOUD_TEAM": "team_0123456789abcdef0123"]) { $1 })
    }

    /// The machine's team comes from its cmux-next record (`team`), the one `cloud.machine.list` answers.
    @Test func theRecordNamesTheMachinesTeam() throws {
        func record(_ json: String) throws -> CloudMachine? {
            CloudMachine(next: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        }
        #expect(try record(#"{"id":"vm_abc123","status":"running","team":"team_0123456789abcdef0123","desktop":true}"#)?.team == "team_0123456789abcdef0123")
        #expect(try record(#"{"id":"vm_abc123","status":"running"}"#)?.team == nil)
    }

    /// The bridge waits for the dial line as long as its caller says: a cold machine resumes inside the
    /// dial's 180 s deadline before the carrier answers, so a dial's bridge waits that long plus 2 s.
    @Test func theBridgeWaitsAsLongAsItsCallerSays() async throws {
        let cli = try Self.standIn("sleep 1\nprintf '{\"ok\":true}\\n' >&2\n")
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let short = DaemonBridge(executable: cli.path, arguments: [], replyTimeoutMs: 100)
        await #expect(throws: DaemonError.self) { _ = try await Task.detached { try short.openStream() }.value }
        let long = DaemonBridge(executable: cli.path, arguments: [], replyTimeoutMs: 10_000)
        try await Task.detached { try long.openStream() }.value.close()
        let dial = try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))
        #expect(dial.bridge(cli: cli, environment: [:]).replyTimeoutMs == 182_000)
    }

    /// Each dial runs the bundled CLI's `carrier dial` with the credential in its environment: here a
    /// stand-in that answers the dial line on stderr and echoes its argv and the three variables as the stream.
    @Test(arguments: [CloudCarrierDial.Service.mux, .desktop]) func theDialRunsCarrierDialWithTheCredential(service: CloudCarrierDial.Service) async throws {
        let cli = try Self.standIn("printf '{\"ok\":true,\"path_state\":\"relay\",\"route\":\"carrier\"}\\n' >&2\nprintf '%s ' \"$@\" \"$CMUX_CLOUD_API_URL\" \"$CMUX_CLOUD_ACCESS_TOKEN\" \"$CMUX_CLOUD_TEAM\"\n")
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let dial = try #require(CloudCarrierDial(machine: "vm_abc123", service: service))
        let opened = dial.bridging(cli: cli) { ["CMUX_CLOUD_API_URL": "https://p", "CMUX_CLOUD_ACCESS_TOKEN": "t-1", "CMUX_CLOUD_TEAM": "team_x"] }
        let bridge = try await opened()
        let stream = try await Task.detached { try bridge.openStream() }.value
        var bytes = Data()
        while let chunk = await stream.read() { bytes.append(chunk) }
        stream.close()
        #expect(String(decoding: bytes, as: UTF8.self) == "carrier dial --machine vm_abc123 --service \(service.rawValue) --deadline-ms 180000 https://p t-1 team_x ")
    }

    /// A refused dial throws, and its code maps to the Cloud sidebar's link wording step by step.
    @Test(arguments: [("service_refused", 6), ("ticket", 2), ("relay", 3), ("parked_timeout", 4), ("handshake", 5)])
    func aRefusedDialNamesItsStep(code: String, exit: Int) async throws {
        let cli = try Self.standIn("printf '{\"ok\":false,\"error_code\":\"\(code)\"}\\n' >&2\nexit \(exit)\n")
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let bridge = try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux)).bridge(cli: cli, environment: [:])
        var refusal: DaemonError?
        do { _ = try await Task.detached { try bridge.openStream() }.value } catch let error as DaemonError { refusal = error }
        let expected: CloudLinkError = switch code {
        case "relay": .disconnected(reason: code)
        case "parked_timeout": .notUp(state: code)
        default: .failed(code: code, message: "")
        }
        #expect(CloudCarrierDial.linkError(refusal) == expected)
        #expect(CloudCarrierDial.linkError(.connectionClosed(reason: "eof")) == nil)
        #expect(CloudCarrierDial.linkError(nil) == nil)
    }

    /// The carrier link opens no socket and asks no app-server op; its owner answer is the record's creator.
    @Test func theCarrierLinkHasNoSocketAndTheCreatorOwnsIt() async throws {
        #expect(CloudCallerOwnership(creator: "u1", caller: "u1") == .owner)
        #expect(CloudCallerOwnership(creator: "u1", caller: "u2") == .team)
        #expect(CloudCallerOwnership(creator: nil, caller: "u1") == .unknown)
        #expect(CloudCallerOwnership(creator: "u1", caller: nil) == .unknown)
        let link = CloudLinkSession(key: CloudLinkKey(machine: "vm_abc123"), resolver: CloudCarrierResolver { .owner })
        let ticket = try await link.connect(origin: .user)
        #expect(await link.currentSocket == nil)
        #expect(await link.currentLinkSocket == nil)
        #expect(await link.ownerLink != nil)
        #expect(try await link.endpoint(ticket) == "")
        // The connection asking again is its drop: the link ends until the next connect.
        await #expect(throws: CloudLinkError.self) { _ = try await link.endpoint(ticket) }
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
