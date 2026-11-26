@testable import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The owner's model credentials for Cloud chats (``CloudAgentCredentials``): the connection the
/// Cloud start chose is read at the chat's start, and a ChatGPT plan token is pushed again to every
/// live agent on that connection about ten minutes before it expires, on the injected clock.
@MainActor
@Suite
struct CloudAgentCredentialRefresherTests {
    @Test(arguments: ["ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"])
    func decodesTheSavedClaudeTokenForCloud(name: String) throws {
        let reply = Data(#"{"family":"claude","kind":"claude-token","env":{"\#(name)":"sk-ant-oat-fixture"}}"#.utf8)
        let credential = try #require(CloudAgentCredential(connectionID: "claude-token", reply: reply))
        #expect(credential.env == [name: "sk-ant-oat-fixture"])
        #expect(credential.endpoint == nil)
    }

    @Test func endpointReplyNamesTheMachineModelAndRedactsValues() throws {
        let data = Data(#"""
        {"family":"opencode","kind":"endpoint","harness":"opencode","model":"byo/org/second","env":{"CMUX_BYO_API_KEY":"fixture-secret"},
        "endpoint":{"kind":"openai","baseUrl":"https://provider.example","models":["first","org/second"]}}
        """#.utf8)
        let credential = try #require(CloudAgentCredential(connectionID: "custom", reply: data))
        #expect(credential.harness == "opencode")
        #expect(credential.model == "byo/org/second")
        #expect(!credential.debugDescription.contains("fixture-secret"))
        #expect(!credential.debugDescription.contains("provider.example"))
        #expect(Mirror(reflecting: credential).children.allSatisfy { $0.label != "endpoint" && $0.label != "env" })
    }

    nonisolated static let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// This Mac's acpmux as the test drives it: each read answers the next token, expiring an hour later.
    @MainActor
    final class Acpmux {
        var reads = 0
        var fails = false
        var expiry: TimeInterval
        let clock: ManualClock

        init(clock: ManualClock, expiresIn: TimeInterval = 3_600) {
            self.clock = clock
            expiry = CloudAgentCredentialRefresherTests.base.timeIntervalSince1970 + expiresIn
        }

        /// Added to the clock's offset (a test that moves the wall clock alone).
        var wallOffset: TimeInterval = 0
        var now: Date { CloudAgentCredentialRefresherTests.base.addingTimeInterval(Double(clock.now.offset.components.seconds) + wallOffset) }

        func read(_ id: String) throws -> CloudAgentCredential {
            reads += 1
            if fails { throw CloudAgentCredentials.Failure.unavailable(connection: id) }
            // A refreshed token whenever fewer than ten minutes are left on the last one.
            if expiry - now.timeIntervalSince1970 <= 600 { expiry = now.timeIntervalSince1970 + 3_600 }
            return CloudAgentCredential(connectionID: id, family: "codex", kind: CloudAgentCredential.chatGPTPlan,
                                        env: ["CMUX_CHATGPT_ACCESS_TOKEN": "token-\(reads)"], expiresAt: Date(timeIntervalSince1970: expiry))
        }
    }

    /// A wall clock a test moves by hand.
    final class Wall: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        var offset: TimeInterval {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// One machine session's received pushes.
    final class Machine: @unchecked Sendable {
        private let lock = NSLock()
        private var got: [[String: String]] = []
        var answer: CloudAgentCredentialRefresher.PushOutcome = .delivered
        var pushes: [[String: String]] { lock.withLock { got } }

        var push: CloudAgentCredentialRefresher.Push {
            { [self] env in lock.withLock { got.append(env); return answer } }
        }
    }

    private func make(_ clock: ManualClock, _ acpmux: Acpmux) -> CloudAgentCredentialRefresher {
        CloudAgentCredentialRefresher(clock: clock, now: { [clock] in Self.base.addingTimeInterval(Double(clock.now.offset.components.seconds)) },
                                      read: { id in try acpmux.read(id) })
    }

    private func started(_ acpmux: Acpmux) throws -> CloudAgentCredential { try acpmux.read("conn-1") }

    @Test func aChatGPTTokenIsPushedTenMinutesBeforeItExpires() async throws {
        let clock = ManualClock(), acpmux = Acpmux(clock: clock), machine = Machine()
        let refresher = make(clock, acpmux)
        #expect(refresher.track(try started(acpmux), push: machine.push) != nil)
        try await clock.waitForSleeper()
        #expect(clock.sleeperDeadlines == [ManualClock.Instant(offset: .seconds(3_000))], "50 minutes into the hour")
        clock.advance(by: .seconds(2_999))
        #expect(machine.pushes.isEmpty && acpmux.reads == 1)
        clock.advance(by: .seconds(1))
        try await clock.waitForSleeper()
        #expect(machine.pushes == [["CMUX_CHATGPT_ACCESS_TOKEN": "token-2"]])
        // The next one 50 minutes into the new token's hour.
        #expect(clock.sleeperDeadlines == [ManualClock.Instant(offset: .seconds(3_000 + 3_000))])
    }

    @Test func oneReadServesEveryAgentOnTheConnection() async throws {
        let clock = ManualClock(), acpmux = Acpmux(clock: clock), first = Machine(), second = Machine()
        let refresher = make(clock, acpmux)
        let credential = try started(acpmux)
        refresher.track(credential, push: first.push)
        refresher.track(credential, push: second.push)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(3_000))
        try await clock.waitForSleeper()
        #expect(acpmux.reads == 2, "one read for both")
        #expect(first.pushes.count == 1 && second.pushes.count == 1)
        #expect(first.pushes == second.pushes)
    }

    @Test func aTokenThatDoesNotExpireIsNotTracked() {
        let clock = ManualClock(), acpmux = Acpmux(clock: clock)
        let refresher = make(clock, acpmux)
        let claude = CloudAgentCredential(connectionID: "c", family: "claude", kind: "api-key",
                                          env: ["ANTHROPIC_API_KEY": "sk-ant-api03-x"], expiresAt: nil)
        #expect(refresher.track(claude, push: Machine().push) == nil)
        #expect(refresher.trackedCount == 0 && clock.sleeperCount == 0)
    }

    @Test func aFailedReadOrPushIsTriedAgainAMinuteLater() async throws {
        let clock = ManualClock(), acpmux = Acpmux(clock: clock), machine = Machine()
        let refresher = make(clock, acpmux)
        refresher.track(try started(acpmux), push: machine.push)
        try await clock.waitForSleeper()
        acpmux.fails = true
        clock.advance(by: .seconds(3_000))
        try await clock.waitForSleeper()
        #expect(clock.sleeperDeadlines == [ManualClock.Instant(offset: .seconds(3_060))])
        acpmux.fails = false
        machine.answer = .failed
        clock.advance(by: .seconds(60))
        try await clock.waitForSleeper()
        #expect(machine.pushes.count == 1)
        #expect(clock.sleeperDeadlines == [ManualClock.Instant(offset: .seconds(3_120))], "the push failed: again in a minute")
        machine.answer = .delivered
        clock.advance(by: .seconds(60))
        try await clock.waitForSleeper()
        #expect(machine.pushes.count == 2)
        #expect(clock.sleeperDeadlines.first.map { $0.offset > .seconds(3_120 + 600) } == true, "on the new token's schedule")
    }

    @Test func aRefusedRefreshNotifiesTheChatAndStopsRetrying() async throws {
        let clock = ManualClock(), acpmux = Acpmux(clock: clock), machine = Machine()
        let wall = Wall()
        var notices = 0
        var reads = 0
        let refresher = CloudAgentCredentialRefresher(clock: clock,
            now: { Self.base.addingTimeInterval(wall.offset) },
            read: { _ in
                reads += 1
                throw CloudAgentCredentials.Failure.refused(reason: "chatgpt.reauth_required")
            })
        refresher.track(try started(acpmux), onReauth: { notices += 1 }, push: machine.push)
        wall.offset = 3_000
        await refresher.refresh("conn-1")
        await refresher.refresh("conn-1")
        #expect(reads == 1 && notices == 1)
        #expect(refresher.trackedCount == 0)
        #expect(machine.pushes.isEmpty)
    }

    @Test func aChatThatIsGoneIsNoLongerRefreshed() async throws {
        let clock = ManualClock(), acpmux = Acpmux(clock: clock), machine = Machine()
        machine.answer = .gone
        // The wall clock moves to the refresh time; the refresh pass runs here, not on its timer.
        let wall = Wall()
        let refresher = CloudAgentCredentialRefresher(clock: clock, now: { Self.base.addingTimeInterval(wall.offset) },
                                                      read: { id in try acpmux.read(id) })
        refresher.track(try started(acpmux), push: machine.push)
        wall.offset = 3_000
        acpmux.wallOffset = 3_000
        await refresher.refresh("conn-1")
        #expect(machine.pushes.count == 1)
        #expect(refresher.trackedCount == 0, "the push said the chat is gone: no more refreshes")
    }

    @Test func anUntrackedAgentStopsItsTimer() async throws {
        let clock = ManualClock(), acpmux = Acpmux(clock: clock)
        let refresher = make(clock, acpmux)
        let id = try #require(refresher.track(try started(acpmux), push: Machine().push))
        try await clock.waitForSleeper()
        refresher.untrack(id)
        #expect(refresher.trackedCount == 0)
    }

    @Test func aChatStartsOnTheConnectionTheCloudStartChoseReadAtItsStart() async throws {
        var asked: [String] = []
        let credentials = CloudAgentCredentials { id in
            asked.append(id)
            return Data(#"{"family":"claude","kind":"api-key","env":{"ANTHROPIC_API_KEY":"sk-ant-api03-abc"},"expires_at":null}"#.utf8)
        }
        #expect(try await credentials.launchCredential(chat: "tab-1", machine: "m1") == nil, "no choice: the machine's own route")
        credentials.use(choice: .connection(id: "route-claude", family: "claude"), chat: "tab-1", machine: "m1")
        let launch = try #require(try await credentials.launchCredential(chat: "tab-1", machine: "m1"))
        #expect(asked == ["route-claude"])
        #expect(launch.env == ["ANTHROPIC_API_KEY": "sk-ant-api03-abc"] && launch.family == "claude" && !launch.refreshes)
        #expect(!String(describing: launch).contains("sk-ant") && !String(reflecting: launch).contains("sk-ant"))
        var dumped = ""
        dump(launch, to: &dumped)
        #expect(!dumped.contains("sk-ant"), "the mirror names the variable only")
        // Spent once the chat started on it.
        credentials.started(chat: "tab-1", machine: "m1", on: launch) { _ in .delivered }
        #expect(credentials.connectionChoice(chat: "tab-1", machine: "m1") == nil)
    }

    @Test func aChosenConnectionThatCannotBeReadRefusesTheStart() async {
        let credentials = CloudAgentCredentials { _ in Data(#"{"error":"nope"}"#.utf8) }
        credentials.use(choice: .connection(id: "gone", family: "claude"), chat: "tab", machine: "m")
        await #expect(throws: CloudAgentCredentials.Failure.unavailable(connection: "gone")) {
            try await credentials.launchCredential(chat: "tab", machine: "m")
        }
    }

    /// A chat no Cloud start chose for (`cmux chat --on vm`'s `cloud start-session`, a new chat in a
    /// machine's workspace) launches on the connection Cloud first use picks for its harness: the
    /// Claude Code login, which never serves Cloud, is skipped for the token; a harness nothing serves,
    /// or a pick that cannot be read, starts on the machine's own route instead of refusing.
    @Test func aChatNoStartChoseForLaunchesOnCloudFirstUsesPick() async throws {
        var asked: [String] = []
        var unreadable = false
        let credentials = CloudAgentCredentials { id in
            asked.append(id)
            if unreadable { return Data(#"{"error":"nope"}"#.utf8) }
            return Data(#"{"family":"claude","kind":"api-key","env":{"ANTHROPIC_API_KEY":"sk-ant-api03-abc"},"expires_at":null}"#.utf8)
        }
        #expect(try await credentials.launchCredential(chat: "cli-tab", machine: "m1", harness: "claude") == nil, "no rule set: the machine's own route")
        credentials.setup = CloudSetup(read: {
            CloudSetup.Snapshot(personal: [CloudSetup.Connection(id: "claude-login", families: ["claude"], servesCloud: false),
                                           CloudSetup.Connection(id: "anthropic-key", families: ["claude"])], organization: nil)
        })
        let launch = try #require(try await credentials.launchCredential(chat: "cli-tab", machine: "m1", harness: "claude", model: "opus"))
        #expect(asked == ["anthropic-key"] && launch.env.keys.sorted() == ["ANTHROPIC_API_KEY"])
        #expect(try await credentials.launchCredential(chat: "cli-tab", machine: "m1", harness: "codex") == nil && asked.count == 1, "nothing serves codex: no read")
        unreadable = true
        #expect(try await credentials.launchCredential(chat: "cli-tab", machine: "m1", harness: "claude") == nil, "an unreadable pick is the machine's own route")
        // A Cloud start's own choice still wins over the rule.
        unreadable = false
        credentials.use(choice: .connection(id: "route-claude", family: "claude"), chat: "cli-tab", machine: "m1")
        _ = try await credentials.launchCredential(chat: "cli-tab", machine: "m1", harness: "claude")
        #expect(asked.last == "route-claude")
    }

    @Test func anotherMacCannotDeliverOrWithdrawTheSameNamedConnection() async throws {
        let instance = UUID().uuidString
        let data = try keyReply(kind: "api-key", instance: instance, key: "fixture-key")
        let owner = CloudAgentCredentials(machineIdentity: "first-mac") { _ in data }
        let credential = try await owner.credential(forConnection: "anthropic-key")
        let expected = try #require(owner.credentialBinding(credential))

        // Even a copied route file with the same instance does not prove ownership on this Mac.
        let other = CloudAgentCredentials(machineIdentity: "second-mac") { _ in data }
        #expect(try await other.boundCredential(expected, model: nil, harness: "claude") == nil)
        let machine = Machine()
        other.readCredentialConnections = {
            .init(connections: [.init(id: "anthropic-key", families: ["claude"], servesCloud: false,
                                      canServeCloud: true, credentialInstance: instance)],
                  disconnected: ["anthropic-key": [instance]])
        }
        await other.restoreBinding(expected, chat: "chat", machine: "guest", sessionID: "session", harness: "claude", model: nil,
                                   replace: { await machine.push($0?.env ?? [:]) }, onDelivered: {}, onRefusal: { _ in })
        #expect(machine.pushes.isEmpty)
    }

    @Test func replacingAKeyKeepsTheBindingAndDeletingThenAddingBreaksIt() async throws {
        let machine = Machine()
        let original = UUID().uuidString
        var instance = original
        var key = "fixture-first"
        var listed: [CloudSetup.Connection]? = [.init(id: "anthropic-key", families: ["claude"], credentialInstance: instance)]
        let credentials = CloudAgentCredentials(machineIdentity: "mac") { _ in
            try keyReply(kind: "api-key", instance: instance, key: key)
        }
        credentials.readCredentialConnections = { listed.map { .init(connections: $0) } }
        let first = try await credentials.credential(forConnection: "anthropic-key")
        let expected = try #require(credentials.credentialBinding(first))
        credentials.started(chat: "chat", machine: "guest", on: first, push: machine.push)
        await credentials.keySync?.value
        #expect(machine.pushes == [first.env])

        key = "fixture-rotated"
        credentials.credentialConnectionsChanged()
        await credentials.keySync?.value
        #expect(try await credentials.boundCredential(expected, model: nil, harness: "claude")?.env["ANTHROPIC_API_KEY"] == key)
        #expect(machine.pushes.last?["ANTHROPIC_API_KEY"] == key)

        listed = []
        credentials.credentialConnectionsChanged()
        await credentials.keySync?.value
        #expect(machine.pushes.count == 2)

        instance = UUID().uuidString
        key = "fixture-new-connection"
        listed = [.init(id: "anthropic-key", families: ["claude"], credentialInstance: instance)]
        credentials.credentialConnectionsChanged()
        await credentials.keySync?.value
        #expect(try await credentials.boundCredential(expected, model: nil, harness: "claude") == nil)
        #expect(machine.pushes.count == 2)
    }

    @Test(arguments: ["chatgpt.keychain_other_build", "chatgpt.keychain_locked", "chatgpt.storage"])
    func reattachingWithAnUnreadableGrantSendsNothing(reason: String) async throws {
        let machine = Machine()
        let instance = UUID().uuidString
        let credentials = CloudAgentCredentials(machineIdentity: "mac") { _ in
            throw CloudAgentCredentials.Failure.refused(reason: reason)
        }
        let credential = CloudAgentCredential(connectionID: "chatgpt", family: "codex", kind: "chatgpt-plan",
                                              env: ["CMUX_CHATGPT_ACCESS_TOKEN": "fixture"], expiresAt: .now.addingTimeInterval(3_600),
                                              instance: instance)
        let binding = try #require(credentials.credentialBinding(credential))
        for signedIn in [false, true] {
            credentials.readCredentialConnections = {
                .init(connections: [.init(id: "chatgpt", families: ["codex"], signedIn: signedIn, credentialInstance: instance)])
            }
            await credentials.restoreBinding(binding, chat: "chat", machine: "guest", sessionID: "session", harness: "codex", model: nil,
                                             replace: { await machine.push($0?.env ?? [:]) }, onDelivered: {}, onRefusal: { _ in })
        }
        #expect(machine.pushes.isEmpty)
    }

    @Test func credentialsWithoutAnInstanceStillTrackLegacyChatGPTRefresh() throws {
        let credentials = CloudAgentCredentials()
        let credential = CloudAgentCredential(connectionID: "chatgpt", family: "codex", kind: "chatgpt-plan",
                                              env: ["CMUX_CHATGPT_ACCESS_TOKEN": "fixture"], expiresAt: .now.addingTimeInterval(3_600))
        #expect(credentials.started(chat: "chat", machine: "guest", on: credential, push: Machine().push) != nil)
        #expect(credentials.refresher.trackedCount == 1)
    }

    @Test func reEnablingCloudUseRedeliversToTheOpenChat() async throws {
        let machine = Machine()
        let instance = UUID().uuidString
        var cloudOn = true
        let credentials = CloudAgentCredentials(machineIdentity: "mac") { _ in
            try keyReply(kind: "api-key", instance: instance, key: "fixture-first")
        }
        credentials.readCredentialConnections = {
            .init(connections: [.init(id: "key", families: ["claude"], servesCloud: cloudOn,
                                      canServeCloud: true, credentialInstance: instance)])
        }
        let first = try await credentials.credential(forConnection: "key")
        credentials.started(chat: "chat", machine: "guest", on: first, push: machine.push)
        await credentials.keySync?.value
        cloudOn = false
        credentials.credentialConnectionsChanged()
        await credentials.keySync?.value
        cloudOn = true
        credentials.credentialConnectionsChanged()
        await credentials.keySync?.value
        #expect(machine.pushes == [first.env, [:], first.env])
    }

    @Test(arguments: [false, true])
    func reconcilingTheSameClaudeSetupTokenKeepsTheGuestAgentRunning(supportsEndpointCredentials: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("r14-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = #"""
        import json, socket, sys
        from pathlib import Path

        directory = Path(sys.argv[1])
        capabilities = [
            'agent-session-attach-v1', 'agent-session-start-v1', 'agent-session-start-vm-kind-v1',
            'agent-session-start-credentials-v1', 'agent-session-bound-credentials-v1',
            'agent-session-credential-reattach-v1',
        ]
        if sys.argv[2] == 'true':
            capabilities.append('agent-session-start-endpoint-credentials-v1')

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(str(directory / 'guest.sock'))
            server.listen()
            print('ready', flush=True)
            held = None
            while True:
                connection, _ = server.accept()
                with connection, connection.makefile('rb') as requests:
                    for line in requests:
                        frame = json.loads(line)
                        command = frame.get('cmd')
                        data = {}
                        if command == 'identify':
                            data = {'app':'cmux-tui', 'protocol':12, 'generation':'fixture', 'capabilities':capabilities}
                        elif command == 'agent-session-start':
                            held = frame['credentials']['env']
                            data = {'session':'durable-chat'}
                        elif command == 'agent-session-credentials':
                            assert held and frame['session'] == 'durable-chat'
                            restart = 'none' if frame['env'] == held else 'now'
                            held = frame['env']
                            with (directory / 'restart').open('a') as record:
                                record.write(restart + '\n')
                            data = {'restart':restart}
                        reply = json.dumps({'id':frame['id'], 'ok':True, 'data':data})
                        connection.sendall((reply + '\n').encode())
        """#
        let daemon = Process()
        let ready = Pipe()
        daemon.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        daemon.arguments = ["-u", "-c", script, directory.path, String(supportsEndpointCredentials)]
        daemon.standardOutput = ready
        try daemon.run()
        defer { if daemon.isRunning { daemon.terminate() } }
        let readyReader = ready.fileHandleForReading
        let readiness = try await Task.detached { try readyReader.read(upToCount: 1) }.value
        try #require(readiness == Data("r".utf8))
        let endpoint: AgentSessionAttachClient.EndpointProvider = {
            DaemonEndpoint(socketPath: directory.appendingPathComponent("guest.sock").path)
        }
        let ownerLink: AgentSessionAttachClient.OwnerLink = { 3 }
        let instance = UUID().uuidString
        let id = "claude-token"
        let reply = Data(#"{"family":"claude","kind":"claude-token","credential_instance":"\#(instance)","env":{"ANTHROPIC_AUTH_TOKEN":"sk-ant-oat01-fixture"}}"#.utf8)
        let credentials = CloudAgentCredentials(machineIdentity: "mac") { _ in reply }
        credentials.readCredentialConnections = {
            .init(connections: [.init(id: id, families: ["claude"], servesCloud: true, credentialInstance: instance)])
        }
        let credential = try await credentials.credential(forConnection: id)
        let binding = try #require(credentials.credentialBinding(credential))
        let client = AgentSessionAttachClient(surface: 7, endpoint: endpoint)
        let session = try await client.start(cwd: "/w", harness: "claude", ownerLink: ownerLink,
                                             credentials: credential.env, credentialConnection: binding)
        await client.close()

        let replace = CloudAgentCredentialRefresher.machineReplace(surface: 7, sessionID: session,
                                                                   ownerLink: ownerLink, reconnect: nil, endpoint: endpoint)
        credentials.started(chat: "chat", machine: "guest", sessionID: session, on: credential, replace: replace,
                            push: { _ in Issue.record("expected the bound credential delivery"); return .failed })
        await credentials.keySync?.value
        credentials.credentialConnectionsChanged()
        await credentials.keySync?.value

        let restarts = try String(contentsOf: directory.appendingPathComponent("restart"), encoding: .utf8)
        #expect(restarts.split(whereSeparator: \.isNewline) == ["none", "none"])
    }

    @Test func anUnsupportedWithdrawalKeepsItsDeliveryForAReconnect() async throws {
        let instance = UUID().uuidString
        var cloudOn = false
        let credentials = CloudAgentCredentials(machineIdentity: "mac") { _ in
            try keyReply(kind: "api-key", instance: instance, key: "fixture-key")
        }
        credentials.readCredentialConnections = {
            .init(connections: [.init(id: "key", families: ["claude"], servesCloud: cloudOn,
                                      canServeCloud: true, credentialInstance: instance)])
        }
        let first = try await credentials.credential(forConnection: "key")
        let outcome = Machine()
        let replace = CloudAgentCredentialRefresher.machineReplace(surface: 7, sessionID: "session",
            ownerLink: { 3 }, reconnect: nil, endpoint: {
                throw AgentSessionAttachError(code: AgentSessionAttachClient.startUnsupported, message: "fixture refusal")
            })
        credentials.started(chat: "chat", machine: "guest", sessionID: "session", on: first, replace: { credential in
            _ = await outcome.push(credential?.env ?? [:])
            return await replace(credential)
        }, push: outcome.push)
        await credentials.keySync?.value
        #expect(outcome.pushes == [[:]])

        credentials.credentialConnectionsChanged()
        await credentials.keySync?.value
        #expect(outcome.pushes == [[:], [:]])

        cloudOn = true
        credentials.credentialConnectionsChanged()
        await credentials.keySync?.value
        #expect(outcome.pushes == [[:], [:], first.env])
    }

    @Test func reattachRetriesARefusedWithdrawalOfAnExplicitDisconnect() async throws {
        let machine = Machine()
        let clock = ManualClock()
        let instance = UUID().uuidString
        var state = CloudAgentCredentials.ConnectionState(connections: [
            .init(id: "copilot", families: ["github-copilot"], credentialInstance: instance)
        ])
        let credentials = CloudAgentCredentials(machineIdentity: "mac", clock: clock) { _ in
            try keyReply(kind: "copilot-plan", instance: instance, key: "fixture-first")
        }
        credentials.readCredentialConnections = { state }
        let first = try await credentials.credential(forConnection: "copilot")
        let binding = try #require(credentials.credentialBinding(first))
        credentials.started(chat: "chat", machine: "guest", sessionID: "session", on: first, push: machine.push)
        await credentials.keySync?.value

        // A missing connection has no authority to withdraw.
        state = .init(connections: [])
        credentials.credentialConnectionsChanged()
        await credentials.keySync?.value
        #expect(machine.pushes == [first.env])

        state = .init(connections: [], disconnected: ["copilot": [instance]])
        machine.answer = .failed
        credentials.credentialConnectionsChanged()
        await credentials.keySync?.value
        #expect(machine.pushes == [first.env, [:]])

        // The guest can finish adopting the host without another settings or link event.
        try await clock.waitForSleeper()
        clock.advance(by: CloudAgentCredentialRefresher.retry)
        try await clock.waitForSleeper()
        #expect(machine.pushes == [first.env, [:], [:]])

        machine.answer = .delivered
        await credentials.restoreBinding(binding, chat: "chat", machine: "guest", sessionID: "session", harness: "opencode", model: nil,
                                         replace: { await machine.push($0?.env ?? [:]) }, onDelivered: {}, onRefusal: { _ in })
        #expect(machine.pushes == [first.env, [:], [:], [:]])
    }

    private func keyReply(kind: String, instance: String, key: String) throws -> Data {
        let copilot = kind == "copilot-plan"
        return try JSONSerialization.data(withJSONObject: [
            "family": copilot ? "github-copilot" : "claude", "kind": kind, "credential_instance": instance,
            "env": [copilot ? "CMUX_COPILOT_GITHUB_TOKEN" : "ANTHROPIC_API_KEY": key]
        ])
    }

    @Test func machineSignInAndRecoveryStayOnTheChatMachine() async throws {
        let setup = CloudSetup(read: { .init(personal: [.init(id: "saved-claude", families: ["claude"])], organization: []) })
        var openedMachine: String?
        var openedSession: String?
        setup.openConnectionSettings = { family, machine, _, _, session in
            #expect(family == "claude")
            openedMachine = machine
            openedSession = session
        }
        let credentials = CloudAgentCredentials(read: { _ in
            Issue.record("a machine-login chat tried to read a Mac token")
            return Data()
        })
        credentials.setup = setup
        credentials.use(chat: "draft", machine: "vm_b", claudeAuth: .own)
        credentials.move(chat: "draft", to: "chat", machine: "vm_b")
        #expect(try await credentials.launchCredential(chat: "chat", machine: "vm_b", harness: "claude") == nil)
        credentials.openModelConnectionSettings(machine: "vm_b", harness: "claude-work", session: "session-b")
        #expect(openedMachine == "vm_b")
        #expect(openedSession == "session-b")
    }

    /// The Cloud start hands its choice to the launch: a `.connection` names its id, every other choice
    /// none, and a tab that got another key than the start planned keeps the choice.
    @Test func theStartsChoiceReachesTheLaunchUnderTheTabsKey() {
        let choice = CloudSetup.Choice.connection(id: "route-claude", family: "claude")
        #expect(choice.connectionID == "route-claude")
        #expect(CloudSetup.Choice.organization(family: "claude").connectionID == nil && CloudSetup.Choice.fallback.connectionID == nil)
        let credentials = CloudAgentCredentials()
        credentials.use(choice: choice, chat: "planned", machine: "m1")
        credentials.move(chat: "planned", to: "tab-9", machine: "m1")
        #expect(credentials.connectionChoice(chat: "tab-9", machine: "m1") == choice && credentials.connectionChoice(chat: "planned", machine: "m1") == nil)
        credentials.move(chat: "none", to: "tab-9", machine: "m1")
        #expect(credentials.connectionChoice(chat: "tab-9", machine: "m1") == choice, "no choice to move leaves the tab's own")
    }

    @Test(arguments: ["gemini", "grok"])
    func aPendingStartRefusesAReplacementUnderTheSameConnectionID(family: String) async throws {
        let id = "saved-key"
        let original = UUID().uuidString
        var current = original
        var key = "original-fixture"
        let variable = family == "gemini" ? "GEMINI_API_KEY" : "XAI_API_KEY"
        let setup = CloudSetup(read: { .init(personal: [.init(id: id, families: [family], credentialInstance: current)], organization: []) })
        let credentials = CloudAgentCredentials { _ in
            try JSONSerialization.data(withJSONObject: ["family": family, "kind": "api-key", "credential_instance": current, "env": [variable: key]])
        }
        credentials.setup = setup
        let choice = await setup.choose(harness: family, model: nil, account: id)
        let refusal = CloudAgentCredentials.Failure.unavailable(connection: id)

        current = UUID().uuidString
        key = "replacement-fixture"
        credentials.use(choice: choice, chat: "planned", machine: "vm", harness: family)
        credentials.move(chat: "planned", to: "opened", machine: "vm")
        await #expect(throws: refusal) {
            try await credentials.launchCredential(chat: "opened", machine: "vm", harness: family)
        }
        await #expect(throws: refusal) {
            try await credentials.launchCredential(for: choice, harness: family, model: nil)
        }

        let newLaunch = try #require(try await credentials.launchCredential(chat: "new", machine: "vm", harness: family))
        #expect(newLaunch.instance == current && newLaunch.env[variable] == key)
    }
}
