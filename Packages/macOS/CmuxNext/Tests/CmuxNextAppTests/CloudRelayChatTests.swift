import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// `cmux cloud relay-chat` sends a prompt to an agent on a Cloud machine in the order link, owner check, send. No login moves:
/// the machine's Claude and Codex reach models through the Cloud service's model route (its edge injects the machine's
/// token), so nothing from this Mac's sign-ins is read, copied or asked about before the send.
@MainActor @Suite(.serialized)
struct CloudRelayChatTests {
    /// A fresh running Cloud machine with nothing inherited: no start-session ran on it first, no link is up.
    /// `owns` and `teammate`: the link's connect answer once it is up.
    static func fixture(owns: Bool = true, teammate: Bool = false) -> (services: AppServices, machine: CloudMachineSession) {
        let services = MachineIconTests.services()
        AppActions.bind(services)
        let id = "vm_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20)
        let machine = CloudTestLink.session(id: id, status: .running, name: "Icon VM", owns: owns, teammate: teammate, mainWork: services.mainWork)
        services.machines.add(machine)
        return (services, machine)
    }

    static func invocation(_ machine: CloudMachineSession, agent: String = "claude", origin: ActionOrigin = .cli) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .machine, id: machine.machineID),
                         arguments: ["agent": .string(agent), "prompt": .string("hello")], origin: origin)
    }

    /// What happened, in order: the link step's `connect` or `link`, then the relay's `send` (from its transport, another thread).
    nonisolated final class Steps: @unchecked Sendable {
        static let shared = Steps()
        private let lock = NSLock()
        private var steps: [String] = []
        func append(_ step: String) { lock.withLock { steps.append(step) } }
        func take() -> [String] { lock.withLock { defer { steps = [] }; return steps } }
    }

    /// The platform's relay: records each send and answers one turn that ends with "Hello".
    nonisolated final class RelayRoute: URLProtocol {
        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/x-ndjson"])
            else { return }
            Steps.shared.append(url.path.contains("credential") || url.path.contains("login") ? "login request" : "send")
            let lines = #"{"kind":"sent"}"# + "\n" + #"{"kind":"started","session":"s-1"}"# + "\n" + #"{"kind":"done","stop_reason":"end_turn","reply":"Hello"}"# + "\n"
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(lines.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    static var relay: CloudRelayChat {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayRoute.self]
        return CloudRelayChat(baseURL: URL(string: "https://relay.standin.invalid") ?? URL(fileURLWithPath: "/"), accessToken: { "fixture-access" },
                              teamID: { nil }, session: URLSession(configuration: configuration))
    }

    /// Runs the relay chat on a link that answers `link` (nil: no link up), and answers its result and the steps' order.
    static func relayChat(agent: String = "claude", origin: ActionOrigin = .cli, link: CloudCallerOwnership? = .owner) async throws
        -> (result: Result<[String: ActionResultValue], ActionWorkFailure>?, work: ActionWorkFailure??, steps: [String]) {
        let f = fixture(owns: link == .owner, teammate: link == .team)
        defer { f.machine.disconnect() }
        _ = Steps.shared.take()
        CloudStartSession.bindRelayChat(into: f.services.registry, context: AppActionContext(services: f.services), reason: { nil },
                                        steps: .init(relay: { Self.relay }, link: { _ in true }))
        if link != nil { _ = try await #require(f.machine.appLink).connect(origin: .script) }
        let invoke = try #require(f.services.registry.action(for: "cloudRelayChat")?.invoke)
        var run: (work: [ActionWork], results: [ActionResultWork]) = ([], [])
        _ = f.services.registry.capturingRefusal { run = f.services.registry.capturingRun { invoke(Self.invocation(f.machine, agent: agent, origin: origin)) } }
        let result = await run.results.first?.value
        let work = await run.work.first?.value
        return (result, work, Steps.shared.take())
    }

    static func fields(_ result: Result<[String: ActionResultValue], ActionWorkFailure>?) throws -> [String: ActionResultValue] {
        guard case .success(let fields) = result else { Issue.record("no relay answer: \(String(describing: result))"); return [:] }
        return fields
    }

    /// The owner's machine: the prompt goes straight to the relay, with no login step and no login request before it, for
    /// Claude and Codex alike (both use the machine's model route).
    @Test(arguments: ["claude", "codex"])
    func anOwnersMachineSendsWithNoLoginStep(agent: String) async throws {
        let run = try await Self.relayChat(agent: agent, link: .owner)
        #expect(run.steps == ["send"], "\(agent): \(run.steps)")
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(true) && fields["reply"] == .string("Hello"))
        #expect(fields["login_reason"] == nil && fields["error_code"] == nil)
    }

    /// A known teammate's machine (its link answered `team`): never sent, for any agent, with the app's own teammate refusal.
    @Test(arguments: ["claude", "codex", "pi"])
    func aKnownTeammatesMachineSendsNothing(agent: String) async throws {
        let run = try await Self.relayChat(agent: agent, link: .team)
        #expect(run.steps == [], "\(agent) was sent")
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.team_machine"))
        #expect(fields["error_message"] == .string(AgentRemoteStartRefusal.teamMachine(machine: "Icon VM").userMessage))
    }

    /// An owner answer nobody read (`unknown`), or no link at all: unverified, never sent, with start-session's command.
    @Test func anUnreadOwnerAnswerIsUnverified() async throws {
        for link in [CloudCallerOwnership.unknown, nil] {
            let run = try await Self.relayChat(link: link)
            #expect(run.steps == [], "\(link?.rawValue ?? "no link") was sent")
            let fields = try Self.fields(run.result)
            #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.owner_unverified"))
            #expect(fields["command"].map { "\($0)".contains("cmux cloud start-session --target machine:") } == true)
            guard case .string(let message) = fields["error_message"] else { Issue.record("no message"); continue }
            #expect(!message.localizedCaseInsensitiveContains("login") && !message.contains("Sign in"), "\(message)")
        }
    }

    /// The link's three answers, as the relay reads them.
    @Test func theLinkReadsThreeOwnershipStates() async throws {
        for (owns, teammate, expected) in [(true, false, CloudCallerOwnership.owner), (false, true, .team), (false, false, .unknown)] {
            let link = try #require(Self.fixture(owns: owns, teammate: teammate).machine.appLink)
            #expect(await link.callerOwnership == .unknown, "no link up: unknown")
            _ = try await link.connect(origin: .script)
            #expect(await link.callerOwnership == expected)
        }
    }

    /// A cold machine: running, no start-session first, no link up. The relay chat's own link step connects it, then sends.
    static func cold(_ status: CloudMachine.Status = .running, connect: @escaping @Sendable () throws -> Void) -> (services: AppServices, machine: CloudMachineSession) {
        let services = MachineIconTests.services()
        AppActions.bind(services)
        let id = "vm_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20)
        let machine = CloudTestLink.session(id: id, status: status, name: "Cold VM", mainWork: services.mainWork, opened: connect)
        services.machines.add(machine)
        return (services, machine)
    }

    static func coldRun(_ f: (services: AppServices, machine: CloudMachineSession)) async throws -> (fields: [String: ActionResultValue], steps: [String]) {
        _ = Steps.shared.take()
        CloudStartSession.bindRelayChat(into: f.services.registry, context: AppActionContext(services: f.services), reason: { nil },
                                        steps: .init(relay: { Self.relay }))
        let invoke = try #require(f.services.registry.action(for: "cloudRelayChat")?.invoke)
        let run = f.services.registry.capturingRun { invoke(Self.invocation(f.machine)) }
        let fields = try Self.fields(await run.results.first?.value)
        return (fields, Steps.shared.take())
    }

    @Test func aColdMachineConnectsThenSends() async throws {
        let f = Self.cold { Steps.shared.append("connect") }
        defer { f.machine.disconnect() }
        #expect(await f.machine.appLink?.currentLinkSocket == nil, "not cold")
        let run = try await Self.coldRun(f)
        #expect(run.steps == ["connect", "send"])
        #expect(run.fields["delivered"] == .bool(true))
    }

    /// A cold machine whose link never comes up: nothing sent, `not_connected`, so `cloud start-chat` runs start-session.
    @Test func aColdMachineThatDoesNotConnectSendsNothing() async throws {
        let f = Self.cold { Steps.shared.append("connect"); throw CloudLinkError.disconnected(reason: "link down") }
        defer { f.machine.disconnect() }
        let run = try await Self.coldRun(f)
        #expect(run.steps == ["connect"])
        #expect(run.fields["delivered"] == .bool(false) && run.fields["error_code"] == .string("cloud.relay.not_connected"))
        guard case .string(let command) = run.fields["command"] else { Issue.record("no recovery command"); return }
        #expect(command.hasPrefix("cmux cloud start-session --target machine:"))
    }

    /// A cold paused machine, and a cold one resuming: no connect, no send, `machine_not_ready` with start-session's command.
    @Test func aColdPausedOrResumingMachineSendsNothingAndNamesTheStartThatResumesIt() async throws {
        for status in [CloudMachine.Status.paused, .starting] {
            let f = Self.cold(status) { Steps.shared.append("connect") }
            defer { f.machine.disconnect() }
            let run = try await Self.coldRun(f)
            #expect(run.steps == [], "\(status): \(run.steps)")
            #expect(run.fields["delivered"] == .bool(false) && run.fields["error_code"] == .string("cloud.relay.machine_not_ready"), "\(status)")
            guard case .string(let command) = run.fields["command"] else { Issue.record("\(status): no recovery command"); continue }
            #expect(command.hasPrefix("cmux cloud start-session --target machine:" + f.machine.machineID), "\(status): \(command)")
        }
    }

    /// A cold machine whose record status is not known yet: no connect, no send, `not_connected`.
    @Test func aColdMachineOfUnknownStatusSendsNothing() async throws {
        let f = Self.cold(.unknown) { Steps.shared.append("connect") }
        defer { f.machine.disconnect() }
        let run = try await Self.coldRun(f)
        #expect(run.steps == [], "\(run.steps)")
        #expect(run.fields["delivered"] == .bool(false) && run.fields["error_code"] == .string("cloud.relay.not_connected"))
    }

    /// The signed-in account a test switches while the link step waits.
    nonisolated final class Account: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String?] = ["user-1", "team-A"]
        var now: [String?] { lock.withLock { value } }
        func switchTo(_ account: [String?]) { lock.withLock { value = account } }
    }

    /// Runs a CLI relay chat whose link step is `link` and whose account is `account`; the send is recorded.
    static func linkRun(account: Account, linkWithin: Duration = CloudStartSession.linkWithin,
                        link: @escaping @MainActor (CloudMachineSession) async -> Bool) async throws -> [String: ActionResultValue] {
        let f = fixture()
        defer { f.machine.disconnect() }
        _ = Steps.shared.take()
        CloudStartSession.bindRelayChat(into: f.services.registry, context: AppActionContext(services: f.services), reason: { nil },
                                        steps: .init(relay: { Self.relay }, linkWithin: linkWithin, link: link, account: { account.now }))
        let invoke = try #require(f.services.registry.action(for: "cloudRelayChat")?.invoke)
        let run = f.services.registry.capturingRun { invoke(Self.invocation(f.machine)) }
        return try Self.fields(await run.results.first?.value)
    }

    /// The account changes while the link step is suspended: nothing is sent, and the run answers `account_changed`.
    @Test func anAccountChangeWhileTheLinkWaitsSendsNothing() async throws {
        let account = Account()
        // The switch lands while the link step is suspended, after the run read the account it started for.
        let fields = try await Self.linkRun(account: account) { _ in
            Steps.shared.append("link")
            account.switchTo(["user-2", "team-B"])
            return true
        }
        #expect(Steps.shared.take() == ["link"], "a send ran for another account")
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.account_changed"))
    }

    /// The link answers after the run's `linkWithin` ran out: the run has already answered `link_pending`, and the
    /// link's late answer sends nothing.
    @Test func aLinkThatAnswersAfterTheDeadlineSendsNothing() async throws {
        let (late, answer) = AsyncStream.makeStream(of: Void.self)
        let fields = try await Self.linkRun(account: Account(), linkWithin: .milliseconds(50)) { _ in
            Steps.shared.append("link")
            for await _ in late { break }
            return true
        }
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.link_pending"))
        guard case .string(let message) = fields["error_message"] else { Issue.record("no message"); return }
        #expect(!message.localizedCaseInsensitiveContains("login"), "\(message)")
        answer.yield()
        answer.finish()
        #expect(Steps.shared.take() == ["link"], "the late link sent")
    }

    /// The person's own run (the palette) on a teammate's machine sees the refusal, and nothing is sent.
    @Test func thePersonsRunIsRefusedTheSameWay() async throws {
        let run = try await Self.relayChat(origin: .user, link: .team)
        #expect(run.steps == [])
        let failure = try #require(run.work ?? nil, "the person's refused relay chat answered no failure")
        let shown = failure.shownReason ?? failure.message
        #expect(shown == AgentRemoteStartRefusal.teamMachine(machine: "Icon VM").userMessage || failure.message == AgentRemoteStartRefusal.teamMachine(machine: "Icon VM").userMessage, "\(failure)")
    }

    /// No answer field carries the bearer the relay used.
    @Test func noAnswerCarriesTheAccessToken() async throws {
        for link in [CloudCallerOwnership.owner, .team, nil] {
            let fields = try Self.fields(try await Self.relayChat(link: link).result)
            #expect(!fields.values.contains { "\($0)".contains("fixture-access") })
        }
    }
}
