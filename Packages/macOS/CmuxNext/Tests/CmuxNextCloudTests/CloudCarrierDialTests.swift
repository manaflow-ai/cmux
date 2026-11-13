@testable import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextWakeupsTestSupport
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

    /// A socket another serve holds (serve's `bad_request` naming the path, exit 64) is a clear failure.
    @Test func aTakenSocketIsAClearFailure() async throws {
        let cli = try Self.standIn("printf '{\"ok\":false,\"error_code\":\"bad_request\",\"error_detail\":\"Unix socket path /tmp/mine.sock is already leased\",\"route\":\"carrier\"}\\n' >&2\nexit 64\n")
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) { [:] }
        let serve = CloudCarrierServe(connector: connector, socket: "/tmp/mine.sock") { _ in }
        await #expect(throws: CloudLinkError.failed(code: "socket", message: "another cmux is serving this machine's connection socket")) {
            _ = try await serve.socketPath()
        }
    }

    /// Serve's exits (#37278) as link failures: before ready, a path it could not claim is the taken socket and
    /// `ticket` (2) and `handshake` (5) keep the dial's wording; after ready, the listener failing (`socket`, 6)
    /// ends serve, and a refused stdin line (`bad_request`) is not a refused connection.
    @Test func serveRefusalsReadAsTheirFailures() {
        let socket = "/tmp/x/cmux-link-0123456789ab.sock"
        #expect(CloudCarrierDial.serveStartError(code: "bad_request", detail: "Unix socket path \(socket) is already leased", socket: socket)
            == CloudCarrierDial.socketTaken)
        #expect(CloudCarrierDial.serveStartError(code: "bad_request", detail: "usage: cmux carrier serve --machine vm_… --socket PATH", socket: socket)
            == .failed(code: "bad_request", message: "bad_request: usage: cmux carrier serve --machine vm_… --socket PATH"))
        #expect(CloudCarrierDial.serveStartError(code: "ticket", detail: "no credential", socket: socket) == .failed(code: "ticket", message: "ticket: no credential"))
        #expect(CloudCarrierDial.serveStartError(code: "handshake", detail: nil, socket: socket) == .failed(code: "handshake", message: ""))
        #expect(CloudCarrierDial.serveRefusal(code: "bad_request", detail: "a stdin line is too long") == nil)
        #expect(CloudCarrierDial.serveRefusal(code: "socket", detail: "accept failed") == .helperNotRunning(reason: "cmux carrier serve stopped listening: accept failed"))
        #expect(CloudCarrierDial.serveRefusal(code: "parked_timeout", detail: nil) == .notUp(state: "parked_timeout"))
    }

    /// A child that serves another socket than the one asked for is refused.
    @Test func aServeOnAnotherSocketIsRefused() async throws {
        let cli = try Self.standIn("printf '{\"ok\":true,\"socket\":\"/tmp/elsewhere.sock\",\"route\":\"carrier\"}\\n' >&2\ncat >/dev/null\n")
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) { [:] }
        let serve = CloudCarrierServe(connector: connector, socket: "/tmp/mine.sock") { _ in }
        await #expect(throws: CloudLinkError.invalidAnswer("served another socket")) { _ = try await serve.socketPath() }
    }

    /// Ownership is the current child's latest connected line: its `vmk`, and a line without one is never
    /// owner (nor the record's creator rule); the creator rule applies only before that child answered.
    /// A new child starts with no answer.
    @Test func theGrantsVmkOwnsTheLinkElseTheRecord() async throws {
        #expect(CloudCallerOwnership(vmk: "owner") == .owner)
        #expect(CloudCallerOwnership(vmk: "team") == .team)
        #expect(CloudCallerOwnership(vmk: nil) == nil)
        #expect(CloudCallerOwnership(vmk: "admin") == nil)
        // Each token line (a connect's) lets the stand-in answer: first an owner grant, then one with no vmk.
        let cli = try Self.standIn("printf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\nread -r l\nprintf '{\"ok\":true,\"route\":\"carrier\",\"vmk\":\"owner\"}\\n' >&2\nread -r l\nprintf '{\"ok\":true,\"route\":\"carrier\"}\\n' >&2\ncat >/dev/null\n")
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) {
            ["CMUX_CLOUD_ACCESS_TOKEN": "t"]
        }
        let serve = CloudCarrierServe(connector: connector, socket: "/tmp/cmux-link-0123456789ab.sock") { _ in }
        let link = CloudLinkSession(key: CloudLinkKey(machine: "vm_abc123"), resolver: CloudCarrierResolver(serve: serve) { .owner })
        // No connected line yet: the record says owner.
        _ = try await link.connect(origin: .user)
        #expect(await serve.answer == nil)
        #expect(await link.callerOwnership == .owner)
        _ = try await link.connect(origin: .user)
        var deadline = ContinuousClock.now + .seconds(5)
        while await serve.answer != .owner, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await serve.answer == .owner)
        // An answer with no vmk takes the owner role away, on the live link and on the next connect.
        _ = try await link.connect(origin: .user)
        deadline = ContinuousClock.now + .seconds(5)
        while await serve.answer != .unknown, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await serve.answer == .unknown)
        #expect(await link.ownerLink == nil)
        _ = try await link.connect(origin: .user)
        #expect(await link.callerOwnership == .unknown, "the record's creator rule overrode a connection's answer")
        #expect(await link.ownerLink == nil)
        // A new child has answered nothing yet: the record's rule again.
        await serve.stop()
        _ = try await link.connect(origin: .user)
        #expect(await serve.answer == nil)
        #expect(await link.callerOwnership == .owner)
        await link.close()
    }

    /// A token lookup that fails keeps the healthy serve child (on its last token) rather than restarting it.
    @Test func aFailedTokenLookupKeepsTheChild() async throws {
        let cli = try Self.standIn("d=$(dirname \"$0\")\necho launched >> \"$d/launches\"\nprintf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\ncat >/dev/null\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tokens = Counter()
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) {
            guard await tokens.next() == 1 else { throw CancellationError() }
            return ["CMUX_CLOUD_ACCESS_TOKEN": "t-1"]
        }
        let socket = "/tmp/cmux-link-0123456789ab.sock"
        let serve = CloudCarrierServe(connector: connector, socket: socket) { _ in }
        #expect(try await serve.socketPath() == socket)
        #expect(try await serve.socketPath() == socket)
        #expect(await serve.refusal == nil, "the child was torn down")
        #expect(try String(contentsOf: folder.appendingPathComponent("launches"), encoding: .utf8) == "launched\n")
        await serve.stop()
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

    /// A connected line's `vmk` updates the live link's ownership, not only the next connect's.
    @Test func aConnectedLinesVmkUpdatesTheLiveLink() async throws {
        let cli = try Self.standIn("d=$(dirname \"$0\")\nprintf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\nwhile [ ! -f \"$d/go\" ]; do sleep 0.05; done\nprintf '{\"ok\":true,\"route\":\"carrier\",\"vmk\":\"team\"}\\n' >&2\ncat >/dev/null\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) { [:] }
        let serve = CloudCarrierServe(connector: connector, socket: "/tmp/cmux-link-0123456789ab.sock") { _ in }
        let link = CloudLinkSession(key: CloudLinkKey(machine: "vm_abc123"), resolver: CloudCarrierResolver(serve: serve) { .owner })
        let ticket = try await link.connect(origin: .user)
        _ = try await link.endpoint(ticket)
        #expect(await link.ownerLink != nil)
        try Data().write(to: folder.appendingPathComponent("go"))
        let deadline = ContinuousClock.now + .seconds(5)
        while await link.callerOwnership != .team, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await link.callerOwnership == .team)
        #expect(await link.ownerLink == nil)
        #expect(await link.stateWord == "attached")
        await link.close()
    }

    /// The daemon connection's retry within one connect (and its reconnect) gets the same serve socket
    /// again; the link ends only once serve refused a dial or exited.
    @Test func aRetryReusesTheSocketUntilServeIsGone() async throws {
        let cli = try Self.standIn("d=$(dirname \"$0\")\nprintf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\nwhile [ ! -f \"$d/go\" ]; do sleep 0.05; done\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = "/tmp/cmux-link-0123456789ab.sock"
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) { [:] }
        let serve = CloudCarrierServe(connector: connector, socket: socket) { _ in }
        let link = CloudLinkSession(key: CloudLinkKey(machine: "vm_abc123"), resolver: CloudCarrierResolver(serve: serve) { .owner })
        let ticket = try await link.connect(origin: .user)
        #expect(try await link.endpoint(ticket) == socket)
        #expect(try await link.endpoint(ticket) == socket)
        #expect(await link.stateWord == "attached")
        try Data().write(to: folder.appendingPathComponent("go"))
        let deadline = ContinuousClock.now + .seconds(5)
        while await serve.refusal == nil, ContinuousClock.now < deadline { await Task.yield() }
        await #expect(throws: CloudLinkError.helperNotRunning(reason: "cmux carrier serve exited")) { _ = try await link.endpoint(ticket) }
        #expect(await link.isEnded)
        await link.close()
    }

    /// While serve runs it gets a fresh token line before the last one expires; the loop ends with the child.
    @Test func aRunningServeGetsFreshTokensUntilItExits() async throws {
        let cli = try Self.standIn("d=$(dirname \"$0\")\nprintf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\nwhile read -r l; do echo \"$l\" >> \"$d/stdin\"; done\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tokens = Counter()
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) {
            ["CMUX_CLOUD_ACCESS_TOKEN": "t-\(await tokens.next())"]
        }
        let clock = ManualClock()
        let serve = CloudCarrierServe(connector: connector, socket: "/tmp/cmux-link-0123456789ab.sock", refreshDelay: { _ in .seconds(60) },
                                      clock: clock) { _ in }
        _ = try await serve.socketPath()
        // The first refresh is asleep on the clock; moving the clock past its delay sends the next token.
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(60))
        let stdin = folder.appendingPathComponent("stdin")
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? String(contentsOf: stdin, encoding: .utf8))?.contains(#"{"access_token":"t-2"}"#) != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try String(contentsOf: stdin, encoding: .utf8).hasPrefix(#"{"access_token":"t-2"}"# + "\n"))
        // The refresh after it is asleep on the clock again: the loop runs while the child does.
        try await clock.waitForSleeper()
        #expect(await serve.refreshing)
        await serve.stop()
        #expect(await serve.refreshing == false)
        let asked = await tokens.current()
        // Nothing is left asleep on the clock, so no amount of time asks for another token.
        #expect(clock.sleeperCount == 0, "the refresh loop outlived the child")
        clock.advance(by: .seconds(3_600))
        #expect(await tokens.current() == asked, "the refresh loop outlived the child")
    }

    /// The refresh comes a minute before the token's `exp`, never sooner than 15 s; five minutes without one.
    @Test func theRefreshComesBeforeTheTokenExpires() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func jwt(exp: Int) -> String {
            let payload = Data(#"{"exp":\#(exp)}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "e30.\(payload).sig"
        }
        #expect(CloudCarrierServe.refreshDelay(jwt(exp: 1_000_600), now: now) == .seconds(540))
        #expect(CloudCarrierServe.refreshDelay(jwt(exp: 1_000_030), now: now) == .seconds(15))
        #expect(CloudCarrierServe.refreshDelay("opaque", now: now) == .seconds(300))
    }

    /// stop() while a launch waits for its token never spawns a child (it would carry the old account's token).
    @Test func aStopDuringThePendingTokenSpawnsNothing() async throws {
        let cli = try Self.standIn("d=$(dirname \"$0\")\necho launched >> \"$d/launches\"\nprintf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\ncat >/dev/null\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = Gate()
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) {
            await gate.wait()
            return ["CMUX_CLOUD_ACCESS_TOKEN": "old-account"]
        }
        let serve = CloudCarrierServe(connector: connector, socket: "/tmp/cmux-link-0123456789ab.sock") { _ in }
        let connect = Task { try await serve.socketPath() }
        let deadline = ContinuousClock.now + .seconds(5)
        while await !gate.isWaiting, ContinuousClock.now < deadline { await Task.yield() }
        await serve.stop()
        await gate.open()
        await #expect(throws: CloudLinkError.disconnected(reason: "closed")) { _ = try await connect.value }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("launches").path), "a stopped launch spawned serve")
    }

    /// stop() while a launch waits for the previous child's exit never spawns the next one.
    @Test func aStopDuringThePreviousExitSpawnsNothing() async throws {
        // The first child ignores its stdin closing and exits only on `go`.
        let cli = try Self.standIn("d=$(dirname \"$0\")\necho launched >> \"$d/launches\"\nprintf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\nwhile [ ! -f \"$d/go\" ]; do sleep 0.05; done\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tokens = Counter()
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) {
            ["CMUX_CLOUD_ACCESS_TOKEN": "t-\(await tokens.next())"]
        }
        let serve = CloudCarrierServe(connector: connector, socket: "/tmp/cmux-link-0123456789ab.sock") { _ in }
        _ = try await serve.socketPath()
        await serve.stop()
        // The next connect closes the first child and waits for it to exit.
        let connect = Task { try await serve.socketPath() }
        // The launch closed the first child and waits for its exit, next to the child's own exit watcher.
        let deadline = ContinuousClock.now + .seconds(5)
        while await serve.childExitWaiters < 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await serve.childExitWaiters == 2)
        await serve.stop()
        try Data().write(to: folder.appendingPathComponent("go"))
        await #expect(throws: CloudLinkError.disconnected(reason: "closed")) { _ = try await connect.value }
        #expect(try String(contentsOf: folder.appendingPathComponent("launches"), encoding: .utf8) == "launched\n")
        #expect(await tokens.current() == 1, "a stopped launch asked for a token")
    }

    /// A serve child whose run() throws (no binary there) counts as exited: its waiters resume, the launch
    /// fails as disconnected, and the next launch starts instead of waiting forever for it.
    @Test func aChildThatNeverRanDoesNotBlockTheNextLaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ccd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appendingPathComponent("cmux-tui")
        let never = ChildProcess(executable: cli, arguments: [])
        #expect(throws: (any Error).self) { try never.startHoldingInput() }
        #expect(!never.isRunning)
        #expect(await never.waitForExit() == ChildProcess.notRun)
        for await _ in never.stderrLines {}

        let socket = folder.appendingPathComponent("cmux-link-0123456789ab.sock").path
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) { [:] }
        let serve = CloudCarrierServe(connector: connector, socket: socket) { _ in }
        do {
            _ = try await serve.socketPath()
            Issue.record("a serve with no binary got ready")
        } catch let error as CloudLinkError {
            guard case .disconnected(let reason) = error else { Issue.record("not disconnected: \(error)"); return }
            #expect(reason.hasPrefix("cmux carrier serve did not start"))
        }
        // The binary appears: the next connect launches it at once.
        try "#!/bin/sh\nprintf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\ncat >/dev/null\n"
            .write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let next = try await withDeadline(.seconds(10), label: "next serve launch") { try await serve.socketPath() }
        #expect(next == socket)
        await serve.stop()
    }

    /// A pause parks the link through the real resolver: the serve child exits, nothing launches while the
    /// machine is paused, and the next connect (a resume) launches a fresh child.
    @Test func aParkStopsTheServeAndTheNextConnectLaunchesAnother() async throws {
        let cli = try Self.standIn("d=$(dirname \"$0\")\necho launched >> \"$d/launches\"\nprintf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\ncat >/dev/null\necho exited >> \"$d/launches\"\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let launches = folder.appendingPathComponent("launches")
        func lines() -> [String] { ((try? String(contentsOf: launches, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        let socket = "/tmp/cmux-link-0123456789ab.sock"
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) { [:] }
        let serve = CloudCarrierServe(connector: connector, socket: socket) { _ in }
        let link = CloudLinkSession(key: CloudLinkKey(machine: "vm_abc123"), resolver: CloudCarrierResolver(serve: serve) { .owner })
        #expect(try await link.endpoint(try await link.connect(origin: .user)) == socket)
        #expect(lines() == ["launched"])

        await link.park(reason: "paused")
        #expect(await link.isEnded)
        let deadline = ContinuousClock.now + .seconds(5)
        while lines() != ["launched", "exited"], ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(lines() == ["launched", "exited"], "the parked serve child exited")
        try await Task.sleep(for: .milliseconds(200))
        #expect(lines() == ["launched", "exited"], "nothing launches while the machine is paused")

        #expect(try await link.endpoint(try await link.connect(origin: .user)) == socket)
        #expect(lines() == ["launched", "exited", "launched"], "the resume launched a fresh child")
        await link.close()
    }

    /// A paused machine's carrier ask from the Cloud app server is refused as paused and starts no serve.
    @Test func aPausedMachinesCarrierAskStartsNoServe() async throws {
        let cli = try Self.standIn("d=$(dirname \"$0\")\necho launched >> \"$d/launches\"\nprintf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\ncat >/dev/null\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) { [:] }
        let serve = CloudCarrierServe(connector: connector, socket: "/tmp/cmux-link-0123456789ab.sock") { _ in }
        let link = CloudLinkSession(key: CloudLinkKey(machine: "vm_abc123"), resolver: CloudCarrierResolver(serve: serve) { .owner })
        let answer = await CloudLinkSession.carrierAnswer(link, machine: "vm_abc123", paused: true)
        #expect(answer == .failure(.init(code: "cloud.machine.paused", message: "vm_abc123 is paused; resume it first")))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("launches").path), "no serve child started")
        await link.close()
    }

    /// A closed child that ignores its stdin closing gets SIGTERM after the grace, so the next launch
    /// (every resume after a pause) is not held forever.
    @Test func aChildThatIgnoresItsClosedStdinIsTerminatedBeforeTheNextLaunch() async throws {
        let cli = try Self.standIn("d=$(dirname \"$0\")\necho launched >> \"$d/launches\"\nprintf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\nwhile [ ! -f \"$d/go\" ]; do sleep 0.05; done\necho exited >> \"$d/launches\"\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = "/tmp/cmux-link-0123456789ab.sock"
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux))) { [:] }
        let serve = CloudCarrierServe(connector: connector, socket: socket) { _ in }
        _ = try await serve.socketPath()
        await serve.stop()
        let next = try await withDeadline(CloudCarrierServe.exitGrace * 3, label: "relaunch past a stuck child") { try await serve.socketPath() }
        #expect(next == socket)
        #expect(try String(contentsOf: folder.appendingPathComponent("launches"), encoding: .utf8) == "launched\nlaunched\n", "the stuck first child was terminated, never let exit on its own")
        // The second child ignores its stdin too: `go` ends it, so no stand-in outlives the test (the first
        // died of the SIGTERM and wrote no `exited`).
        try Data().write(to: folder.appendingPathComponent("go"))
        await serve.stop()
        let launches = folder.appendingPathComponent("launches")
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? String(contentsOf: launches, encoding: .utf8)) != "launched\nlaunched\nexited\n", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private actor Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false
        var isWaiting: Bool { waiter != nil }
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }

    private actor Counter {
        private var value = 0
        func next() -> Int { value += 1; return value }
        func current() -> Int { value }
    }

    /// An account end (``CloudCarrierStreams/endAll()``) closes a running serve child at once and fences its
    /// serve: the old account's socket is handed to no one, and no new child starts for it.
    @Test func anAccountEndClosesTheServeAndFencesItsSocket() async throws {
        let cli = try Self.standIn("d=$(dirname \"$0\")\necho launched >> \"$d/launches\"\nprintf '{\"ok\":true,\"socket\":\"%s\",\"route\":\"carrier\"}\\n' \"$6\" >&2\ncat >/dev/null\necho ended >> \"$d/launches\"\n")
        let folder = cli.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let streams = CloudCarrierStreams()
        let connector = CloudCarrierDial.Connector(cli: cli, dial: try #require(CloudCarrierDial(machine: "vm_abc123", service: .mux)), streams: streams) {
            ["CMUX_CLOUD_ACCESS_TOKEN": "t-1"]
        }
        let socket = "/tmp/cmux-link-0123456789ab.sock"
        let serve = CloudCarrierServe(connector: connector, socket: socket) { _ in }
        #expect(try await serve.socketPath() == socket)
        #expect(streams.count == 1, "the running child is held")
        await streams.endAll().value
        let launches = folder.appendingPathComponent("launches")
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? String(contentsOf: launches, encoding: .utf8)) != "launched\nended\n", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try String(contentsOf: launches, encoding: .utf8) == "launched\nended\n", "the child's stdin closed")
        await #expect(throws: CloudLinkError.disconnected(reason: "closed")) { try await serve.socketPath(keepingRefusal: true) }
        #expect(try String(contentsOf: launches, encoding: .utf8) == "launched\nended\n", "no new child")
        await serve.stop()
    }

    private static func standIn(_ body: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ccd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cli = folder.appendingPathComponent("cmux-tui")
        try ("#!/bin/sh\n" + body).write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return cli
    }

    /// A failed carrier socket ask of the Cloud app server names the carrier step the server maps, never
    /// a credential: a refused start keeps its code, a dropped relay and an unregistered daemon theirs,
    /// anything else is `unavailable`.
    @Test func aCarrierSocketAskFailureNamesTheCarrierStep() {
        let cases: [(CloudLinkError, String)] = [
            (CloudCarrierDial.linkError(code: "ticket", detail: "the platform answered 403"), "ticket"),
            (CloudCarrierDial.linkError(code: "handshake", detail: nil), "handshake"),
            (CloudCarrierDial.linkError(code: "relay", detail: nil), "relay"),
            (CloudCarrierDial.linkError(code: "parked_timeout", detail: nil), "parked_timeout"),
            (CloudCarrierDial.serveStartError(code: "bad_request", detail: "/tmp/s.sock is in use", socket: "/tmp/s.sock"), "socket"),
            (.helperNotRunning(reason: "no bundled cmux-tui"), "unavailable"),
            (.disconnected(reason: "closed"), "unavailable"),
            (.unsupported, "unavailable"),
        ]
        for (error, code) in cases {
            #expect(CloudCarrierDial.carrierRefusal(error).code == code, "\(error)")
        }
        let ticket = CloudCarrierDial.carrierRefusal(CloudCarrierDial.linkError(code: "ticket", detail: "the machine is paused"))
        #expect(ticket.message.contains("paused"), "the server reads a paused machine from the message")
        #expect(CloudCarrierDial.carrierRefusal(CloudCarrierDial.linkError(code: "bad_request", detail: nil)).retryable == false)
    }
}
