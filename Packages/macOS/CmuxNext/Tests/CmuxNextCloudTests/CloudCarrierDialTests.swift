@testable import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// The carrier children the app spawns (design/cloud-carrier.md): one `cmux carrier supervise` per Cloud
/// session, which runs the session's `cmux carrier serve` (its lifecycle is Rust's, cmux-tui
/// `carrier/supervise.rs`; the edge is ``CloudCarrierServeEdgeTests``), and `cmux carrier dial --service
/// desktop` per desktop viewer, with the platform origin, the access token and the machine's team in
/// their environment.
@Suite struct CloudCarrierDialTests {
    @Test(arguments: [CloudCarrierDial.Service.mux, .desktop]) func theDialArgvNamesTheMachineServiceAndDeadline(service: CloudCarrierDial.Service) throws {
        let dial = try #require(CloudCarrierDial(machine: "vm_abc123", service: service))
        #expect(dial.arguments == ["carrier", "dial", "--machine", "vm_abc123", "--service", service.rawValue, "--deadline-ms", "180000"])
        #expect(CloudCarrierDial(machine: "", service: service) == nil)
        #expect(CloudCarrierDial(machine: "vm 1; rm -rf /", service: service) == nil)
    }

    @Test func theSuperviseArgvNamesTheMachineAndSocket() throws {
        let dial = try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))
        #expect(dial.superviseArguments(socket: "/tmp/x/cmux-link-0123456789ab.sock")
            == ["carrier", "supervise", "--machine", "vm_abc123", "--socket", "/tmp/x/cmux-link-0123456789ab.sock"])
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

    /// A desktop dial asks for progress lines; their text reaches the caller in order before the dial line,
    /// and the stream after the dial line is the service's alone.
    @Test func theDesktopDialHandsOverItsProgressText() async throws {
        let cli = try Self.standIn("""
        [ "$CMUX_CARRIER_PROGRESS" = 1 ] || exit 9
        printf '{"progress":{"stage":"waking","text":"Waking up the machine, about 25 s left","eta_ms":25000,"deadline_ms":170000}}\\n' >&2
        printf '{"progress":{"stage":"desktop","text":"Opening the desktop, about 2 s left","eta_ms":2000,"deadline_ms":150000}}\\n' >&2
        printf '{"ok":true,"path_state":"relay","route":"carrier"}\\n' >&2
        printf 'rd'
        """)
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .desktop))) { [:] }
        let (texts, sink) = AsyncStream.makeStream(of: String.self)
        let stream = try await connector.open { sink.yield($0) }
        sink.finish()
        var bytes = Data()
        while let chunk = await stream.read() { bytes.append(chunk) }
        stream.close()
        var seen: [String] = []
        for await text in texts { seen.append(text) }
        #expect(seen == ["Waking up the machine, about 25 s left", "Opening the desktop, about 2 s left"])
        #expect(String(decoding: bytes, as: UTF8.self) == "rd")
        let mux = try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))
        #expect(mux.bridge(cli: cli, environment: [:]).environment["CMUX_CARRIER_PROGRESS"] == nil, "only the desktop dial asks")
    }

    @Test func theRecordsCreatorOwnsTheMachine() {
        #expect(CloudCallerOwnership(creator: "u1", caller: "u1") == .owner)
        #expect(CloudCallerOwnership(creator: "u1", caller: "u2") == .team)
        #expect(CloudCallerOwnership(creator: nil, caller: "u1") == .unknown)
        #expect(CloudCallerOwnership(creator: "u1", caller: nil) == .unknown)
    }

    /// The record's `creator` is the platform's user id (`user_` + the first 20 hex digits of
    /// sha256("stack:<project>:<stack user id>"), the API's `userIdFor`), never the Stack id.
    @Test func theCreatorIsComparedAsAPlatformUserID() {
        // sha256("stack:p:s") starts 02ef07e3bf70025ba891
        let platform = CloudAccessToken.backendUserID(stackProjectID: "p", stackUserID: "s")
        #expect(platform == "user_02ef07e3bf70025ba891")
        #expect(CloudCallerOwnership(creator: platform, caller: platform) == .owner)
        #expect(CloudCallerOwnership(creator: platform, caller: "s") == .team, "the Stack id is another namespace")
    }

    private static func standIn(_ body: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ccd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = folder.appendingPathComponent("cmux-tui")
        try ("#!/bin/sh\n" + body).write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return cli
    }

    /// A serve that refused to start for want of its device key (a DEV build's Keychain that refused it; the
    /// supervisor reports it as `helper_refused`) ends a wait for the link with that reason; the same step refused
    /// by a ready serve, one connection's dial, and a dropped or not yet ready link are dialed again. The reason
    /// is the link's own words with no next step.
    @Test func onlyAHelperThatCannotStartEndsALinkWait() {
        let noKey = CloudLinkError.helperRefused(code: "handshake", message: "handshake: the Keychain refused the carrier key (-128)")
        #expect(CloudLinkError(wire: ["kind": "helper_refused", "code": "handshake", "message": "handshake: the Keychain refused the carrier key (-128)"]) == noKey)
        #expect(CloudLinkError.endsWaits(noKey))
        #expect(CloudLinkError.failureReason(noKey) == "the Keychain refused the carrier key (-128)")
        #expect(CloudCarrierDial.carrierRefusal(noKey).retryable == false, "asking again starts a helper that refuses the same way")
        #expect(CloudCarrierDial.carrierRefusal(noKey).code == "handshake")
        #expect(noKey.description == "Could not connect to the Cloud machine (handshake: the Keychain refused the carrier key (-128)). Click Connect to try again.")
        let healing: [CloudLinkError] = [.failed(code: "handshake", message: "handshake: pin mismatch"),
                                         .failed(code: "ticket", message: "ticket: no credential"),
                                         .disconnected(reason: "relay"), .notUp(state: "parked_timeout"),
                                         .helperNotRunning(reason: "cmux carrier serve missed its deadline")]
        for error in healing {
            #expect(!CloudLinkError.endsWaits(error), "\(error)")
        }
        #expect(CloudLinkError.failureReason(CloudLinkError.helperNotRunning(reason: "cmux carrier serve missed its deadline.")) == "cmux carrier serve missed its deadline")
        #expect(CloudLinkError.failureReason(CloudLinkError.unsupported) == nil)
    }

    /// A failed carrier socket ask of the Cloud app server names the carrier step the server maps, never
    /// a credential: a refused start keeps its code, a dropped relay and an unregistered daemon theirs,
    /// anything else is `unavailable`.
    @Test func aCarrierSocketAskFailureNamesTheCarrierStep() {
        let cases: [(CloudLinkError, String)] = [
            (.failed(code: "ticket", message: "ticket: the platform answered 403"), "ticket"),
            (.failed(code: "handshake", message: ""), "handshake"),
            (.disconnected(reason: "relay"), "relay"),
            (.notUp(state: "parked_timeout"), "parked_timeout"),
            (.failed(code: "socket", message: "another cmux is serving this machine's connection socket"), "socket"),
            (.helperNotRunning(reason: "no bundled cmux-tui"), "unavailable"),
            (.disconnected(reason: "closed"), "unavailable"),
            (.unsupported, "unavailable"),
        ]
        for (error, code) in cases {
            #expect(CloudCarrierDial.carrierRefusal(error).code == code, "\(error)")
        }
        let ticket = CloudCarrierDial.carrierRefusal(CloudLinkError.failed(code: "ticket", message: "ticket: the machine is paused"))
        #expect(ticket.message.contains("paused"), "the server reads a paused machine from the message")
        #expect(CloudCarrierDial.carrierRefusal(CloudLinkError.failed(code: "bad_request", message: "")).retryable == false)
    }
}
