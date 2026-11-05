import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCloudCredentials
import Foundation
import Testing

/// `cmux cloud relay-chat` gives the machine the person's harness login before it sends, as `cloud start-session`
/// does (Leo: "we have the daemon, we have the token, we have the thing that can just send it over the
/// authentication"). A chat that `cloud start-chat` sent first over the relay reached a guest with no Claude login
/// and answered "Claude is not signed in here".
@MainActor @Suite(.serialized)
struct CloudRelayChatLoginTests {
    /// A fresh Cloud machine with nothing inherited: no start-session ran on it first.
    static func fixture() -> (services: AppServices, machine: CloudMachineSession) {
        let services = MachineIconTests.services()
        AppActions.bind(services)
        let id = "vm_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20)
        return (services, MachineIconTests.cloudMachine(services, id: id))
    }

    static func invocation(_ machine: CloudMachineSession, origin: ActionOrigin = .cli) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .machine, id: machine.machineID),
                         arguments: ["agent": .string("claude"), "prompt": .string("hello")], origin: origin)
    }

    /// The app's own binding, with the app's own login step: a CLI relay chat on a fresh machine runs that step
    /// (its decision is on the machine's row) before the relay is asked. Red on a base that sends with no login step.
    @Test func aCLIRelayChatRunsTheHarnessLoginStepFirst() async throws {
        let f = Self.fixture()
        #expect(f.machine.harnessLogin == nil)
        let invoke = try #require(f.services.registry.action(for: "cloudRelayChat")?.invoke, "cloudRelayChat is not bound")
        let run = f.services.registry.capturingRun { invoke(Self.invocation(f.machine)) }
        let task = try #require(run.results.first, "cloud relay chat tracked no result")
        _ = await task.value
        #expect(f.machine.harnessLogin?.provider == .claude, "the relay chat was sent with no harness login step")
    }

    // MARK: The order and the outcomes, with the login step and the relay's transport stood in for

    /// What happened, in order: the login step's `login`, then the relay's `send` (from its transport, another thread).
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
            Steps.shared.append("send")
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

    /// A Claude login decision on a machine the person owns, as the login step leaves it on the machine's row.
    static func decision(requested: CloudHarnessLoginDecision.Choice? = .pass, harness: String = "claude", outcome: String?) -> CloudHarnessLoginDecision {
        var decision = CloudHarnessLoginDecision(dogfood: true, setting: nil, harness: harness, signedIn: true)
        (decision.requested, decision.requestedByPerson, decision.headless) = (requested, requested != nil, true)
        (decision.callerOwns, decision.guestStdout) = (true, "vm-kind:owner\n")
        decision.machineProbe = .init(exitCode: 0, stdout: "none\n")
        decision.outcome = outcome
        return decision
    }

    /// Runs the relay chat bound with a login step that leaves `decision`, and answers its result and the steps' order.
    static func relayChat(_ decision: CloudHarnessLoginDecision, origin: ActionOrigin = .cli, loginTakes: Duration = .zero,
                          loginWithin: Duration = CloudStartSession.loginWithin) async throws
        -> (result: Result<[String: ActionResultValue], ActionWorkFailure>?, work: ActionWorkFailure??, steps: [String]) {
        let f = fixture()
        _ = Steps.shared.take()
        CloudStartSession.bindRelayChat(into: f.services.registry, context: AppActionContext(services: f.services), reason: { nil },
                                        steps: .init(login: { machine, _, still in
                                            Steps.shared.append("login")
                                            if loginTakes > .zero { try await Task.sleep(for: loginTakes) }
                                            machine.harnessLogin = decision
                                            try still()
                                        }, relay: { Self.relay }, loginWithin: loginWithin))
        let invoke = try #require(f.services.registry.action(for: "cloudRelayChat")?.invoke)
        var run: (work: [ActionWork], results: [ActionResultWork]) = ([], [])
        _ = f.services.registry.capturingRefusal { run = f.services.registry.capturingRun { invoke(Self.invocation(f.machine, origin: origin)) } }
        let result = await run.results.first?.value
        let work = await run.work.first?.value
        return (result, work, Steps.shared.take())
    }

    static func fields(_ result: Result<[String: ActionResultValue], ActionWorkFailure>?) throws -> [String: ActionResultValue] {
        guard case .success(let fields) = result else { Issue.record("no relay answer: \(String(describing: result))"); return [:] }
        return fields
    }

    /// The login copied: the machine has it before the relay sends, and the reply comes back.
    @Test func aLoginGivenComesBeforeTheSend() async throws {
        let run = try await Self.relayChat(Self.decision(outcome: "installed"))
        #expect(run.steps == ["login", "send"])
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(true) && fields["reply"] == .string("Hello") && fields["session_id"] == .string("s-1"))
    }

    /// No login to give (a harness with no transfer): it still sends, after the step.
    @Test func noLoginToPassStillSends() async throws {
        let run = try await Self.relayChat(Self.decision(harness: "pi", outcome: nil))
        #expect(run.steps == ["login", "send"])
        #expect(try Self.fields(run.result)["delivered"] == .bool(true))
    }

    /// Claude on a fresh machine with no login, and this Mac with none of the person's cached: nothing is sent, and the
    /// answer says how to sign the machine in.
    @Test func anAbsentLoginSendsNothingAndSaysHowToSignIn() async throws {
        let run = try await Self.relayChat(Self.decision(outcome: CloudStartChat.signInInChat))
        #expect(run.steps == ["login"], "the relay sent to a machine with no login")
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.login_missing"))
        guard case .string(let message) = fields["error_message"] else { Issue.record("no message"); return }
        #expect(message.contains("Sign in to Claude") && message.contains("`cmux cloud start-session --target machine:"))
    }

    /// The copy failed: nothing is sent, and the answer carries the copy's fixed text only.
    @Test func aFailedCopySendsNothing() async throws {
        let run = try await Self.relayChat(Self.decision(outcome: CloudStartChat.loginFailed + "The login copy failed."))
        #expect(run.steps == ["login"])
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.login_failed"))
        #expect(fields["error_message"].map { "\($0)".contains("The login copy failed") } == true)
    }

    /// A CLI run with no login choice kept is refused by the rules, as start-session refuses it: nothing is sent,
    /// and the answer is typed with the rules' reason.
    @Test func aRefusedLoginSendsNothingWithATypedCode() async throws {
        let decision = Self.decision(requested: nil, outcome: nil)
        try #require(decision.refusal == .needsLoginChoice)
        let run = try await Self.relayChat(decision)
        #expect(run.steps == ["login"])
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(false) && fields["ended"] == .bool(true))
        #expect(fields["error_code"] == .string("cloud.relay.login_refused"))
        #expect(fields["login_reason"] == .string("needs-login-choice"))
        guard case .string(let message) = fields["error_message"] else { Issue.record("no message"); return }
        #expect(message.contains("--login machine") && message.contains("claude on Icon VM"), "\(message)")
    }

    /// The person said no to the copy, on a machine with no login: nothing is sent.
    @Test func aDeclinedCopySendsNothing() async throws {
        let run = try await Self.relayChat(Self.decision(outcome: CloudStartChat.loginDeclined))
        #expect(run.steps == ["login"])
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.login_declined"))
        guard case .string(let message) = fields["error_message"] else { Issue.record("no message"); return }
        #expect(!message.contains("holds no login"), "a decline is not a missing login: \(message)")
    }

    /// A login step that outlasts its share of the result deadline sends nothing and answers at once, typed, so the
    /// caller never gets a late answer for a prompt the relay sends after it gave up.
    @Test func aSlowLoginStepSendsNothingAndAnswersInTime() async throws {
        let clock = ContinuousClock(), begun = clock.now
        let run = try await Self.relayChat(Self.decision(outcome: "installed"), loginTakes: .seconds(3), loginWithin: .milliseconds(200))
        #expect(clock.now - begun < .seconds(3), "the answer waited for the login step")
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.login_pending"))
        // The step ends on its own; the relay never sends this prompt.
        try await Task.sleep(for: .seconds(4))
        #expect(Steps.shared.take() == [], "the relay sent after the run answered")
        #expect(CloudStartSession.loginWithin + .seconds(20) <= CloudHandlers.answerWithin, "the turn keeps 20 s of the result deadline")
    }

    /// The person's own run (the palette) sees the same refusal, and nothing is sent.
    @Test func thePersonsRunIsRefusedTheSameWay() async throws {
        let run = try await Self.relayChat(Self.decision(outcome: CloudStartChat.signInInChat), origin: .user)
        #expect(run.steps == ["login"])
        let failure = try #require(run.work ?? nil, "the person's refused relay chat answered no failure")
        #expect(failure.message.contains("Sign in to Claude") || failure.shownReason?.contains("Sign in to Claude") == true, "\(failure)")
    }

    /// No answer field carries the bearer the relay used.
    @Test func noAnswerCarriesTheAccessToken() async throws {
        for decision in [Self.decision(outcome: "installed"), Self.decision(outcome: CloudStartChat.signInInChat), Self.decision(requested: nil, outcome: nil)] {
            let fields = try Self.fields(try await Self.relayChat(decision).result)
            #expect(!fields.values.contains { "\($0)".contains("fixture-access") })
        }
    }
}
