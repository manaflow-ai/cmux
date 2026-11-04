// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Darwin
import Foundation
import os
import Testing

@Suite struct MachineConsentTests {
    // MARK: The daemon's answer

    @Test func aGrantedAnswerPassesThroughExactly() throws {
        let status = try #require(MachineConsentStatus(daemonResult: Data(
            #"{"consentRequired":true,"consent":{"screen":"granted","control":"none","grantedAt":"1"},"lastRefusal":null}"#.utf8)))
        #expect(status == MachineConsentStatus(consentRequired: true, screen: true, control: false))
        let wire = try #require(HelperWire.object(status.wire))
        #expect(Set(wire.keys) == ["consentRequired", "consent"])
        #expect(wire["consentRequired"] as? Bool == true)
        #expect(wire["consent"] as? [String: String] == ["screen": "granted", "control": "none"])
    }

    @Test(arguments: [
        #"{"consent":{"screen":"granted","control":"granted"}}"#,
        #"{"consentRequired":1,"consent":{"screen":"granted","control":"granted"}}"#,
        #"{"consentRequired":"false","consent":{"screen":"granted","control":"granted"}}"#,
        #"{"consentRequired":true,"consent":{"screen":"GRANTED","control":"granted"}}"#,
        #"{"consentRequired":true,"consent":{"screen":true,"control":true}}"#,
        #"{"consentRequired":true,"consent":{"screen":"granted"}}"#,
        #"{"consentRequired":false}"#,
        #"[]"#,
        #"not json"#,
    ])
    func anyOtherAnswerIsNoAnswer(_ body: String) {
        #expect(MachineConsentStatus(daemonResult: Data(body.utf8)) == nil)
    }

    @Test func observingNeedsScreenAndActingNeedsBoth() {
        let none = MachineConsentStatus(consentRequired: true, screen: false, control: false)
        let screen = MachineConsentStatus(consentRequired: true, screen: true, control: false)
        let control = MachineConsentStatus(consentRequired: true, screen: false, control: true)
        let both = MachineConsentStatus(consentRequired: true, screen: true, control: true)
        let unjoined = MachineConsentStatus(consentRequired: false, screen: false, control: false)
        #expect(none.missing(for: .observe) == .screen)
        #expect(none.missing(for: .act) == .screen)
        #expect(screen.missing(for: .observe) == nil)
        #expect(screen.missing(for: .act) == .control)
        #expect(control.missing(for: .act) == .screen)
        #expect(both.missing(for: .act) == nil)
        #expect(unjoined.missing(for: .act) == nil)
        #expect(MachineConsentStatus.unavailable.missing(for: .observe) == .screen)
    }

    @Test func theInventoryDecidesWhatOnlyObserves() async {
        let inventory = Data(#"""
            {"tools":[{"name":"get_window_state","annotations":{"readOnlyHint":true}},
                      {"name":"click","annotations":{"readOnlyHint":false}},
                      {"name":"zoom","annotations":{"readOnlyHint":1}},
                      {"name":"type_text"}]}
            """#.utf8)
        let gate = ConsentGate(authority: UnavailableConsent())
        #expect(await gate.requirement(for: "get_window_state") { inventory } == .observe)
        #expect(await gate.requirement(for: "click") { inventory } == .act)
        #expect(await gate.requirement(for: "zoom") { inventory } == .act)
        #expect(await gate.requirement(for: "type_text") { inventory } == .act)
        #expect(await gate.requirement(for: "a_tool_added_later") { inventory } == .act)
        let failing = ConsentGate(authority: UnavailableConsent())
        #expect(await failing.requirement(for: "get_window_state") { throw ToolError("down") } == .act)
    }

    // MARK: The host channel

    @Test func withNoHostEveryAnswerIsUnavailable() async {
        #expect(await HostConsentChannel().current() == .unavailable)
        #expect(await UnavailableConsent().current() == .unavailable)
    }

    @Test(.timeLimit(.minutes(1))) func aHostThatNeverAnswersIsUnavailable() async {
        let channel = HostConsentChannel(timeout: .milliseconds(50))
        _ = channel.attach { _ in }
        #expect(await channel.current() == .unavailable)
    }

    @Test(.timeLimit(.minutes(1))) func theHostSocketCarriesTheHostsAnswerAndAnErrorFailsClosed() async throws {
        let channel = HostConsentChannel(timeout: .seconds(10))
        let link = try HostLink(channel: channel, check: RecordingCheck(.verified))
        #expect(try await link.host.nextLine()["ok"] as? Bool == true)
        // Each question is answered by the host; the helper never reads a home.
        setenv("ACPMUX_HOME", FileManager.default.temporaryDirectory.path, 1)
        defer { unsetenv("ACPMUX_HOME") }
        let script: [(Bool, String, MachineConsentStatus)] = [
            (true, #"{"consentRequired":true,"consent":{"screen":"granted","control":"granted"}}"#,
             MachineConsentStatus(consentRequired: true, screen: true, control: true)),
            (false, #"{"consentRequired":false,"consent":{"screen":"none","control":"none"}}"#, .unavailable),
            (true, #"{"consentRequired":false,"consent":{"screen":"none","control":"none"}}"#,
             MachineConsentStatus(consentRequired: false, screen: false, control: false)),
            (true, #"{"error":"daemon unreachable"}"#, .unavailable),
        ]
        for (ok, result, expected) in script {
            async let answer = channel.current()
            let question = try await link.host.nextLine()
            #expect(question["type"] as? String == "machine_consent")
            #expect(Set(question.keys) == ["type", "id"], "the question carries nothing the answer depends on")
            try link.host.reply(id: try #require(question["id"] as? Int), ok: ok, result: result)
            #expect(await answer == expected)
        }
        // A refusal is forwarded to the host for its record.
        await channel.recordRefusal(surface: .control, tool: "click")
        let refused = try await link.host.nextLine()
        #expect(refused["type"] as? String == "consent_refused")
        #expect(refused["surface"] as? String == "control")
        // The connection closes: it is no longer the host.
        #expect(channel.refusalReason == nil)
        await link.close()
        #expect(channel.refusalReason == .hostUnverified)
        #expect(await channel.current() == .unavailable)
    }

    @Test(.timeLimit(.minutes(1))) func aReplyCountsOnlyOnTheConnectionThatWasAsked() async {
        let channel = HostConsentChannel(timeout: .milliseconds(200))
        let (asked, question) = AsyncStream<Int>.makeStream()
        let first = channel.attach { line in
            if let id = HelperWire.object(line)?["id"] as? Int { question.yield(id) }
        }
        let grant = Data(#"{"consentRequired":false,"consent":{"screen":"granted","control":"granted"}}"#.utf8)
        async let answer = channel.current()
        var questions = asked.makeAsyncIterator()
        let id = await questions.next() ?? 0
        channel.receive(id: id, result: grant, link: first + 1)
        #expect(await answer == .unavailable, "an answer on another connection is ignored")
    }

    // MARK: The socket, on one admitted connection

    /// The bridge's sequence on one connection: deny, then grant, then
    /// revoke. An alternate home in the environment or the request never
    /// changes an answer, a refusal keeps the connection open, and nothing
    /// is cached.
    @Test(.timeLimit(.minutes(1))) func oneConnectionFollowsDenyGrantAndRevoke() async throws {
        let authority = ScriptedAuthority()
        let tools = GatedTools(gate: ConsentGate(authority: authority))
        let client = try Client(tools: tools, consent: authority)
        let alternate = FileManager.default.temporaryDirectory.appending(path: "alternate-acpmux-\(getpid())").path
        setenv("ACPMUX_HOME", alternate, 1)
        defer { unsetenv("ACPMUX_HOME") }
        let redirects: [String: Any] = ["home": alternate, "acpmuxHome": alternate, "socket": "/tmp/other.sock",
                                        "params": ["home": alternate]]

        authority.set(MachineConsentStatus(consentRequired: true, screen: false, control: false))
        var answer = try client.consent(extra: redirects)
        #expect(answer["consentRequired"] as? Bool == true)
        #expect(answer["consent"] as? [String: String] == ["screen": "none", "control": "none"])
        var reply = try client.call("click")
        #expect(reply["code"] as? String == "consent_required")
        #expect(reply["surface"] as? String == "screen")
        #expect(reply["reason"] == nil, "a person's refusal carries no reason")

        authority.set(MachineConsentStatus(consentRequired: true, screen: true, control: true))
        answer = try client.consent(extra: redirects)
        #expect(answer["consent"] as? [String: String] == ["screen": "granted", "control": "granted"])
        reply = try client.call("click")
        #expect(reply["ok"] as? Bool == true)

        authority.set(MachineConsentStatus(consentRequired: true, screen: true, control: false))
        answer = try client.consent(extra: redirects)
        #expect(answer["consent"] as? [String: String] == ["screen": "granted", "control": "none"])
        reply = try client.call("click")
        #expect(reply["code"] as? String == "consent_required")
        #expect(reply["surface"] as? String == "control")
        reply = try client.call("get_window_state")
        #expect(reply["ok"] as? Bool == true, "observing needs screen only")

        #expect(tools.executed.withLock { $0 } == ["click", "get_window_state"])
        #expect(authority.refusals.withLock { $0 } == ["screen:click", "control:click"])
    }

    /// The bridge's preflight passed, then the person revoked before the
    /// call reached the driver: the execution check refuses it.
    @Test(.timeLimit(.minutes(1))) func aRevokeAfterThePreflightStillRefusesAtExecution() async throws {
        let authority = ScriptedAuthority()
        let tools = GatedTools(gate: ConsentGate(authority: authority))
        let client = try Client(tools: tools, consent: authority)
        authority.set(MachineConsentStatus(consentRequired: true, screen: true, control: true))
        let preflight = try client.consent()
        #expect(preflight["consent"] as? [String: String] == ["screen": "granted", "control": "granted"])
        authority.set(MachineConsentStatus(consentRequired: true, screen: false, control: false))
        let reply = try client.call("click")
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["code"] as? String == "consent_required")
        #expect(tools.executed.withLock { $0 }.isEmpty, "nothing executed")
        #expect(authority.refusals.withLock { $0 } == ["screen:click"], "the refusal is recorded")
    }

    // MARK: The controlling host

    /// sr2's A/B exec chain: launcher A forks B, execs the signed helper and
    /// keeps the pipe; B execs the helper too, so B's parent is a signed
    /// helper (or, for any child of the app, the app itself). Simulated: the
    /// stdin holder is the attacker, and the host check would verify any
    /// peer. Nothing on stdin reaches it, no consent is trusted, no call runs.
    @Test(.timeLimit(.minutes(1))) func aLauncherHoldingTheControlPipeNeverGrantsOrRuns() async throws {
        let input = Pipe(), output = Pipe()
        let channel = HostConsentChannel(timeout: .seconds(10))
        let tools = GatedTools(gate: ConsentGate(authority: channel))
        let check = RecordingCheck(.verified)
        let controller = HelperController(input: input.fileHandleForReading.fileDescriptor,
                                          output: output.fileHandleForWriting.fileDescriptor,
                                          tools: tools, consent: channel, hostCheck: check, onExit: { _ in })
        controller.start()
        let attacker = Host(toHelper: input.fileHandleForWriting, fromHelper: output.fileHandleForReading.fileDescriptor)
        let grant = #"{"consentRequired":false,"consent":{"screen":"granted","control":"granted"}}"#
        for id in 1...3 { try attacker.reply(id: id, ok: true, result: grant) }
        try attacker.send(["type": "call", "id": 7, "name": "click", "arguments": [String: Any]()])
        let reply = try await attacker.nextLine()
        #expect(reply["type"] as? String == "error", "stdin runs no tool: \(reply)")
        #expect((reply["error"] as? String)?.contains("unknown control message call") == true)
        let client = try Client(tools: tools, consent: channel)
        let refused = try client.call("click")
        #expect(refused["code"] as? String == "consent_required")
        #expect(refused["reason"] as? String == "host_unverified")
        #expect(refused["error"] as? String
            == ConsentRefusal(surface: .screen, tool: "click", reason: .hostUnverified).description)
        #expect(check.tokens.withLock { $0 }.isEmpty, "the pipe is never a host")
        #expect(tools.executed.withLock { $0 }.isEmpty, "nothing executed")
    }

    /// A child of the app (its parent would pass any parent check) holds the
    /// pipe while the real app answers on the host socket. The child answers
    /// the very question asked, with a grant, first; only the app's denial
    /// counts, and it is a person's refusal: plain consent_required.
    @Test(.timeLimit(.minutes(1))) func stdinAnswersAreIgnoredWhileTheHostDenies() async throws {
        let input = Pipe(), output = Pipe()
        let channel = HostConsentChannel(timeout: .seconds(10))
        let tools = GatedTools(gate: ConsentGate(authority: channel))
        let controller = HelperController(input: input.fileHandleForReading.fileDescriptor,
                                          output: output.fileHandleForWriting.fileDescriptor,
                                          tools: tools, consent: channel, hostCheck: RecordingCheck(.verified),
                                          onExit: { _ in })
        controller.start()
        let child = Host(toHelper: input.fileHandleForWriting, fromHelper: output.fileHandleForReading.fileDescriptor)
        let link = try HostLink(channel: channel, check: RecordingCheck(.verified))
        #expect(try await link.host.nextLine()["ok"] as? Bool == true)
        let client = try Client(tools: tools, consent: channel)
        // The bridge's call blocks on its reply; it is read back as JSON.
        let call = Task { try JSONSerialization.data(withJSONObject: client.call("click")) }
        let question = try await link.host.nextLine()
        let id = try #require(question["id"] as? Int)
        try child.reply(id: id, ok: true, result: #"{"consentRequired":false,"consent":{"screen":"granted","control":"granted"}}"#)
        try child.send(["type": "register_acpmux"])
        #expect(try await child.nextLine()["of"] as? String == "register_acpmux", "the grant line was read first")
        try link.host.reply(id: id, ok: true, result: #"{"consentRequired":true,"consent":{"screen":"none","control":"none"}}"#)
        let reply = try #require(HelperWire.object(try await call.value))
        #expect(reply["code"] as? String == "consent_required")
        #expect(reply["reason"] == nil, "a person's refusal carries no reason")
        #expect((reply["error"] as? String)?.hasPrefix("consent_required: this machine") == true)
        #expect(tools.executed.withLock { $0 }.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func overTheSocketWithNoVerifiedHostTheRefusalSaysWhy() async throws {
        let channel = HostConsentChannel()
        let tools = GatedTools(gate: ConsentGate(authority: channel))
        let client = try Client(tools: tools, consent: channel)
        let reply = try client.call("get_window_state")
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["code"] as? String == "consent_required")
        #expect(reply["reason"] as? String == "host_unverified")
        #expect((reply["error"] as? String)?.hasPrefix(
            "consent_required (host_unverified): Computer Use is off: Computer Use could not verify the cmux app") == true)
        #expect(try client.consent()["consentRequired"] as? Bool == true)
        #expect(tools.executed.withLock { $0 }.isEmpty)
    }

    /// The peer check runs on the connection's own audit token; a refused
    /// peer never becomes the host, an accepted one does until it closes.
    @Test(.timeLimit(.minutes(1))) func theHostSocketChecksEachPeerByItsAuditToken() async throws {
        let channel = HostConsentChannel(timeout: .milliseconds(200))
        let refusing = RecordingCheck(.unverified("not the cmux app"))
        let refused = try HostLink(channel: channel, check: refusing)
        let line = try await refused.host.nextLine()
        #expect(line["error"] as? String == "refused")
        #expect(line["reason"] as? String == "host_unverified")
        await refused.close()
        #expect(channel.refusalReason == .hostUnverified)
        #expect(refusing.tokens.withLock { $0 } == [getpid()], "the token names this connection's peer")

        let accepting = RecordingCheck(.verified)
        let accepted = try HostLink(channel: channel, check: accepting)
        #expect(try await accepted.host.nextLine()["ok"] as? Bool == true)
        #expect(channel.refusalReason == nil)
        await accepted.close()
        #expect(channel.refusalReason == .hostUnverified)
    }

    /// Another signed cmux install passes the code check but does not hold
    /// this launch's host secret: a wrong secret, or no secret line at all,
    /// is refused, it never becomes the host, and the grant it sends in the
    /// same write is never read as an answer.
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func aCodeValidPeerWithoutThisLaunchsSecretIsRefused(wrongSecret: Bool) async throws {
        let channel = HostConsentChannel(timeout: .milliseconds(200))
        let tools = GatedTools(gate: ConsentGate(authority: channel))
        let grant: [String: Any] = ["type": "machine_consent", "id": 1, "ok": true,
                                    "result": ["consentRequired": false,
                                               "consent": ["screen": "granted", "control": "granted"]]]
        let first: [[String: Any]] = wrongSecret ? [["secret": HelperWire.hex(Data(repeating: 8, count: 32))], grant] : [grant]
        let link = try HostLink(channel: channel, check: RecordingCheck(.verified), first: first)
        let line = try await link.host.nextLine()
        #expect(line["error"] as? String == "refused")
        #expect(line["reason"] as? String == "host_unverified")
        await link.close()
        #expect(channel.refusalReason == .hostUnverified)
        let reply = try Client(tools: tools, consent: channel).call("click")
        #expect(reply["reason"] as? String == "host_unverified")
        #expect(tools.executed.withLock { $0 }.isEmpty)
    }

    /// Real, no seam: this test process is not a team-signed cmux app, so
    /// its own audit token (a socketpair peer) fails the real SecCode check,
    /// and the real server refuses it.
    @Test(.timeLimit(.minutes(1))) func theRealCheckRefusesThisTestProcess() async throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        let token = try #require(HostConsentServer.auditToken(descriptors[1]))
        #expect(pid_t(bitPattern: token.val.5) == getpid())
        let verdict = CmuxAppCodeCheck().check(token)
        #expect(verdict != .verified, "\(verdict)")

        let channel = HostConsentChannel()
        let link = try HostLink(channel: channel, check: CmuxAppCodeCheck())
        #expect(try await link.host.nextLine()["reason"] as? String == "host_unverified")
        await link.close()
        #expect(channel.refusalReason == .hostUnverified)
    }

    @Test func onlyAMainCmuxAppIdentifierIsAHost() {
        for identifier in ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next",
                           "com.cmuxterm.app.nightly.cmux-next-stable",
                           "com.cmuxterm.app.rc", "com.cmuxterm.app.debug", "com.cmuxterm.app.staging",
                           "com.cmuxterm.app.debug.next", "com.cmuxterm.app.debug.my.tag2", "com.cmuxterm.app.staging.x1"] {
            #expect(CmuxAppCodeCheck.isMainApp(identifier), "\(identifier)")
        }
        let helpers = ["com.cmuxterm.cua", "com.cmuxterm.cua.dev", "com.cmuxterm.app.computer-use",
                       "com.cmuxterm.app.debug.cua", "com.cmuxterm.app.debug.computer-use",
                       "com.cmuxterm.app.nightly.server-helper", "com.cmuxterm.app.debug.next.cua", "cmux-server-helper"]
        let nearMisses = ["com.cmuxterm.apple", "com.cmuxterm.app.", "com.cmuxterm.app.debug.", "com.cmuxterm.app.debug..x",
                          "com.cmuxterm.app.debug.Tag", "com.cmuxterm.app.debug.my-tag", "com.cmuxterm.app.dev",
                          "com.cmuxterm.app.nightly.other", "com.cmuxterm.app.rc.x", "com.cmuxterm.app.next",
                          "com.cmuxterm.app.debugx", "xcom.cmuxterm.app", "com.cmuxterm.app ", "", "acpmux"]
        for identifier in helpers + nearMisses {
            #expect(!CmuxAppCodeCheck.isMainApp(identifier), "\(identifier)")
        }
        #expect(CmuxAppCodeCheck.requirement == #"anchor apple generic and certificate leaf[subject.OU] = "7WLXT3NR37""#)
    }

    @Test(.timeLimit(.minutes(1))) func theAdmissionReplyAdvertisesTheConsentGate() throws {
        let client = try Client(tools: UnavailableTools(reason: "test"), consent: UnavailableConsent())
        #expect(client.admitted["capabilities"] as? [String] == [ConsentGate.capability])
        #expect(ConsentGate.capability == "machine-consent-gate-v1")
    }

    // MARK: readOnlyHint parity with acpmux's bridge

    /// acpmux's bridge reads the helper's served `tools/list`: a tool is
    /// screen-only exactly when `annotations.readOnlyHint === true` (a JSON
    /// boolean) on the one entry with that name; anything else, including a
    /// name listed twice, is screen+control. The gate must agree.
    @Test(.timeLimit(.minutes(1))) func theGateObservesExactlyWhenTheServedHintIsJSONTrue() async throws {
        let fixture: [(name: String, entry: String, bridge: ConsentRequirement)] = [
            ("hint_true", #"{"name":"hint_true","annotations":{"readOnlyHint":true}}"#, .observe),
            ("hint_false", #"{"name":"hint_false","annotations":{"readOnlyHint":false}}"#, .act),
            ("hint_missing", #"{"name":"hint_missing","annotations":{"title":"x"}}"#, .act),
            ("hint_string", #"{"name":"hint_string","annotations":{"readOnlyHint":"true"}}"#, .act),
            ("hint_number", #"{"name":"hint_number","annotations":{"readOnlyHint":1}}"#, .act),
            ("hint_null", #"{"name":"hint_null","annotations":{"readOnlyHint":null}}"#, .act),
            ("no_annotations", #"{"name":"no_annotations"}"#, .act),
            ("listed_twice", #"{"name":"listed_twice","annotations":{"readOnlyHint":true}}"#, .act),
            ("listed_twice", #"{"name":"listed_twice","annotations":{"readOnlyHint":false}}"#, .act),
        ]
        let inventory = Data(("{\"tools\":[" + fixture.map(\.entry).joined(separator: ",") + "]}").utf8)
        let client = try Client(tools: InventoryTools(inventory: inventory), consent: UnavailableConsent())
        let reply = try client.request(["method": "tools/list"])
        let served = try #require(reply["result"] as? [String: Any])
        let servedData = try JSONSerialization.data(withJSONObject: served)
        let entries = try #require(served["tools"] as? [[String: Any]])
        let gate = ConsentGate(authority: UnavailableConsent())
        for tool in fixture {
            let matching = entries.filter { $0["name"] as? String == tool.name }
            let hint = (matching.first?["annotations"] as? [String: Any])?["readOnlyHint"] as? NSNumber
            let bridgeObserves = matching.count == 1
                && (hint.map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false)
            #expect(bridgeObserves == (tool.bridge == .observe), "\(tool.name): fixture matches the bridge rule")
            #expect(await gate.requirement(for: tool.name) { servedData } == tool.bridge, "\(tool.name)")
        }
        #expect(await gate.requirement(for: "not_in_inventory") { servedData } == .act)
    }

    // MARK: Fixtures

    /// The SecCode step, faked: a fixed verdict, recording the pid of each
    /// audit token it was given.
    final class RecordingCheck: HostCodeChecking {
        let verdict: HostVerification
        let tokens = OSAllocatedUnfairLock<[pid_t]>(initialState: [])
        init(_ verdict: HostVerification) { self.verdict = verdict }
        func check(_ token: audit_token_t) -> HostVerification {
            tokens.withLock { $0.append(pid_t(bitPattern: token.val.5)) }
            return verdict
        }
    }

    /// The app's end of a host consent connection, served by a real
    /// `HostConsentServer.serve` on a socketpair.
    final class HostLink: @unchecked Sendable {
        let host: Host
        private let descriptor: Int32
        private let served: AsyncStream<Void>

        /// This launch's host secret, as `configure` would set it.
        static let secret = Data(repeating: 7, count: 32)

        /// `first`: the lines the app sends at once on connecting (by
        /// default, the right secret).
        init(channel: HostConsentChannel, check: any HostCodeChecking,
             first: [[String: Any]] = [["secret": HelperWire.hex(HostLink.secret)]]) throws {
            var descriptors: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
            descriptor = descriptors[0]
            var noSigPipe: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            host = Host(toHelper: FileHandle(fileDescriptor: descriptors[0]), fromHelper: descriptors[0])
            try host.toHelper.write(contentsOf: first.reduce(into: Data()) { $0 += HelperWire.line($1) })
            let server = HostConsentServer(path: "unused", secret: Self.secret, channel: channel, check: check)
            let serverEnd = descriptors[1]
            let (served, finished) = AsyncStream<Void>.makeStream()
            self.served = served
            Thread {
                server.serve(serverEnd)
                finished.finish()
            }.start()
        }

        /// Closes the app's end and waits until the helper has dropped it.
        func close() async {
            shutdown(descriptor, SHUT_RDWR)
            for await _ in served {}
            Darwin.close(descriptor)
        }
    }

    struct InventoryTools: ToolInvoking {
        let inventory: Data
        func listTools() async throws -> Data { inventory }
        func invoke(name: String, arguments: Data) async throws -> Data { throw ToolError("not in this test") }
    }

    final class ScriptedAuthority: MachineConsentAuthority {
        let state = OSAllocatedUnfairLock(initialState: MachineConsentStatus.unavailable)
        let refusals = OSAllocatedUnfairLock<[String]>(initialState: [])
        func set(_ status: MachineConsentStatus) { state.withLock { $0 = status } }
        func current() async -> MachineConsentStatus { state.withLock { $0 } }
        func recordRefusal(surface: ConsentSurface, tool: String) async {
            refusals.withLock { $0.append("\(surface.rawValue):\(tool)") }
        }
    }

    /// Stands for CuaDriverRuntime: the gate is the last await before a
    /// tool executes.
    final class GatedTools: ToolInvoking {
        let gate: ConsentGate
        let executed = OSAllocatedUnfairLock<[String]>(initialState: [])
        init(gate: ConsentGate) { self.gate = gate }
        func listTools() async throws -> Data {
            Data(#"[{"name":"get_window_state","annotations":{"readOnlyHint":true}},{"name":"click"}]"#.utf8)
        }
        func invoke(name: String, arguments: Data) async throws -> Data {
            let requirement = await gate.requirement(for: name) { try await self.listTools() }
            try await gate.admit(name, requirement: requirement)
            executed.withLock { $0.append(name) }
            return Data("{}".utf8)
        }
    }

    /// An admitted bridge connection to `HelperSocketServer.serve`.
    final class Client: @unchecked Sendable {
        private let descriptor: Int32
        private var buffer = HelperWire.LineBuffer()
        private var nextID = 1
        /// The helper's reply to the secret.
        private(set) var admitted: [String: Any] = [:]

        init(tools: any ToolInvoking, consent: any MachineConsentAuthority) throws {
            var descriptors: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
            descriptor = descriptors[0]
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            try #require(setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                                   socklen_t(MemoryLayout<timeval>.size)) == 0)
            let daemon = ProcessStamp(pid: 10, startSeconds: 1, startMicroseconds: 0)
            let secret = Data([1, 2, 3])
            let admission = AdmissionState()
            admission.configure(AdmissionConfig(helperUID: geteuid(), acpmuxCDHashes: [Data([1])],
                                                acpmuxRequirement: nil, acpmuxDaemons: [daemon], secret: secret))
            let server = HelperSocketServer(path: "unused", admission: admission, inspector: Inspector(daemon: daemon),
                                            tools: tools, consent: consent)
            let serverDescriptor = descriptors[1]
            Thread { server.serve(serverDescriptor) }.start()
            try write(HelperWire.line(["secret": HelperWire.hex(secret)]))
            admitted = try readLine()
            #expect(admitted["ok"] as? Bool == true)
        }

        deinit { close(descriptor) }

        func consent(extra: [String: Any] = [:]) throws -> [String: Any] {
            let reply = try request((["method": "machine/consent"] as [String: Any]).merging(extra) { first, _ in first })
            #expect(reply["ok"] as? Bool == true)
            return try #require(reply["result"] as? [String: Any])
        }

        func call(_ name: String) throws -> [String: Any] {
            try request(["method": "tools/call", "name": name, "arguments": [String: Any]()])
        }

        func request(_ fields: [String: Any]) throws -> [String: Any] {
            let id = nextID
            nextID += 1
            try write(HelperWire.line(fields.merging(["id": id]) { _, new in new }))
            let reply = try readLine()
            #expect(reply["id"] as? Int == id)
            return reply
        }

        private func write(_ data: Data) throws {
            try #require(data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) } == data.count)
        }

        private var pending: [Data] = []

        private func readLine() throws -> [String: Any] {
            while pending.isEmpty {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = read(descriptor, &chunk, chunk.count)
                try #require(count > 0, "the helper must answer and keep the connection open")
                let lines = buffer.append(Data(chunk.prefix(count)))
                pending += try #require(lines)
            }
            return try #require(HelperWire.object(pending.removeFirst()))
        }
    }

    struct Inspector: PeerInspecting {
        let daemon: ProcessStamp
        func facts(forConnection descriptor: Int32, requirement: String?) -> PeerFacts? {
            PeerFacts(uid: geteuid(), stamp: ProcessStamp(pid: 11, startSeconds: 1, startMicroseconds: 0),
                      signatureValid: true, cdhash: Data([1]), satisfiesRequirement: false, ancestors: [daemon])
        }
    }

    /// The cmux app's end of the control pipe.
    final class Host: @unchecked Sendable {
        let toHelper: FileHandle
        let fromHelper: Int32
        private var buffer = HelperWire.LineBuffer()
        private var pending: [Data] = []

        init(toHelper: FileHandle, fromHelper: Int32) {
            self.toHelper = toHelper
            self.fromHelper = fromHelper
        }

        func nextLine() async throws -> [String: Any] {
            while pending.isEmpty {
                let descriptor = fromHelper
                let chunk = await Task.detached {
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    let count = Darwin.read(descriptor, &bytes, bytes.count)
                    return count > 0 ? Data(bytes.prefix(count)) : Data()
                }.value
                try #require(!chunk.isEmpty)
                let lines = buffer.append(chunk)
                pending += try #require(lines)
            }
            return try #require(HelperWire.object(pending.removeFirst()))
        }

        func send(_ fields: [String: Any]) throws {
            try toHelper.write(contentsOf: HelperWire.line(fields))
        }

        func reply(id: Int, ok: Bool, result: String) throws {
            let object = try JSONSerialization.jsonObject(with: Data(result.utf8))
            try toHelper.write(contentsOf: HelperWire.line(["type": "machine_consent", "id": id, "ok": ok,
                                                            "result": object]))
        }
    }
}
