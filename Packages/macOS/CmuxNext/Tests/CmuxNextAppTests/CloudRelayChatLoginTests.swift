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

    static func invocation(_ machine: CloudMachineSession, origin: ActionOrigin = .cli) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .machine, id: machine.machineID),
                         arguments: ["agent": .string("claude"), "prompt": .string("hello")], origin: origin)
    }

    /// The app's own binding, with the app's own login step: a CLI relay chat on a fresh machine runs that step
    /// (its decision is on the machine's row) before the relay is asked. Red on a base that sends with no login step.
    @Test func aCLIRelayChatRunsTheHarnessLoginStepFirst() async throws {
        let f = Self.fixture()
        defer { f.machine.disconnect() }
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
    static func decision(requested: CloudHarnessLoginDecision.Choice? = .pass, harness: String = "claude", outcome: String?,
                         callerOwns: Bool = true, guest: String = "owner", machine: String = "none") -> CloudHarnessLoginDecision {
        var decision = CloudHarnessLoginDecision(dogfood: true, setting: nil, harness: harness, signedIn: true)
        (decision.requested, decision.requestedByPerson, decision.headless) = (requested, requested != nil, true)
        (decision.callerOwns, decision.guestStdout) = (callerOwns, "vm-kind:\(guest)\n")
        decision.machineProbe = .init(exitCode: 0, stdout: machine + "\n")
        decision.outcome = outcome
        return decision
    }

    /// Runs the relay chat bound with a login step that leaves `decision` (nil: no step decided), on a link that answers `link`
    /// (nil: no link up), and answers its result and the steps' order.
    static func relayChat(_ decision: CloudHarnessLoginDecision?, origin: ActionOrigin = .cli, loginTakes: Duration = .zero,
                          loginWithin: Duration = CloudStartSession.loginWithin, accountChanges: Bool = false,
                          link: CloudCallerOwnership? = .owner) async throws
        -> (result: Result<[String: ActionResultValue], ActionWorkFailure>?, work: ActionWorkFailure??, steps: [String]) {
        let f = fixture(owns: link == .owner, teammate: link == .team)
        _ = Steps.shared.take()
        CloudStartSession.bindRelayChat(into: f.services.registry, context: AppActionContext(services: f.services), reason: { nil },
                                        steps: .init(login: { machine, _, still in
                                            Steps.shared.append("login")
                                            if loginTakes > .zero { try await Task.sleep(for: loginTakes) }
                                            machine.harnessLogin = decision
                                            if accountChanges { throw ActionFailure(message: "account changed") }
                                            try still()
                                        }, relay: { Self.relay }, loginWithin: loginWithin, link: { _ in true }))
        if link != nil { _ = try await #require(f.machine.appLink).connect(origin: .script) }
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
        let run = try await Self.relayChat(Self.decision(outcome: CloudCredentialTransfer.CachedLogin.none.startOutcome))
        #expect(run.steps == ["login"], "the relay sent to a machine with no login")
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.login_missing"))
        guard case .string(let message) = fields["error_message"] else { Issue.record("no message"); return }
        #expect(message.contains("Sign in to Claude") && message.contains("`cmux cloud start-session --target machine:"))
        #expect(fields["command"].map { "\($0)".contains("cmux cloud start-session --target machine:") } == true)
    }

    /// The Keychain did not answer (#36834): the machine still has no login, so nothing is sent, the same as none cached.
    @Test func anUnreadableKeychainSendsNothing() async throws {
        let unreadable = try #require(CloudCredentialTransfer.CachedLogin.unreadable.startOutcome)
        let run = try await Self.relayChat(Self.decision(outcome: unreadable))
        #expect(run.steps == ["login"], "the relay sent to a machine with no login")
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.login_missing"))
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
        // The command the refusal's `--login` words go with: one the CLI runs.
        guard case .string(let command) = fields["command"] else { Issue.record("no recovery command"); return }
        #expect(command.hasPrefix("cmux cloud start-session --target machine:vm_") && command.hasSuffix(" --agent claude --login none"), "\(command)")
    }

    /// A login step cancelled before it finished (``CloudStartChat/loginCancelled``): the machine may have no login, so nothing
    /// is sent, with a typed code and the start-session command that runs the step to its end (review23 F1 at a54d3d18).
    @Test func aCancelledLoginSendsNothing() async throws {
        let run = try await Self.relayChat(Self.decision(outcome: CloudStartChat.loginCancelled))
        #expect(run.steps == ["login"], "a cancelled login was sent")
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.login_cancelled"))
        #expect(fields["command"].map { "\($0)".contains("cmux cloud start-session --target machine:") } == true)
        // Its own words: the login was cancelled, not "still getting your login" (login_pending's).
        guard case .string(let message) = fields["error_message"] else { Issue.record("no message"); return }
        #expect(message.contains("was cancelled") && !message.contains("still getting"), "\(message)")
    }

    /// `--login machine` on a machine with no login of its own: the recovery is `--login none` (the chat's Sign in to Claude
    /// card), never the same command, which a kept `machine` choice refuses again (review23 F2).
    @Test func aMissingMachineLoginRecoversWithLoginNone() async throws {
        let missing = Self.decision(requested: .machine, outcome: nil)
        try #require(missing.refusal == .machineLoginMissing)
        let fields = try Self.fields(try await Self.relayChat(missing).result)
        #expect(fields["error_code"] == .string("cloud.relay.login_refused") && fields["login_reason"] == .string("machine-login-missing"))
        guard case .string(let command) = fields["command"] else { Issue.record("no recovery command: \(fields)"); return }
        #expect(command.hasSuffix(" --login none"), "\(command)")
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

    /// A sign-out or team switch while the login step waited: nothing is sent, and the code is a terminal login one.
    @Test func anAccountChangeDuringTheLoginSendsNothing() async throws {
        let run = try await Self.relayChat(Self.decision(outcome: "installed"), accountChanges: true)
        #expect(run.steps == ["login"])
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.login_account_changed"))
    }

    /// The composed candidate's capture (HQ run 42133312336): with no link, the owner answer was never asked, the step
    /// skipped (`caller-not-owner`) and the relay sent to a machine with no login. A skip is never ready: nothing is sent,
    /// and the code sends the caller to start-session, which connects and asks the owner answer.
    @Test func aSkippedLoginWithNoLinkSendsNothing() async throws {
        let skipped = Self.decision(outcome: nil, callerOwns: false)
        try #require(skipped.step == .skip && skipped.reason == .callerNotOwner && skipped.provider == .claude)
        let run = try await Self.relayChat(skipped, link: nil)
        #expect(run.steps == ["login"], "a skipped login was sent")
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.login_unverified"))
        #expect(fields["login_reason"] == .string("caller-not-owner"))
    }

    /// A known teammate's machine (its link answered `team`): never sent, for any agent, with the app's own teammate refusal.
    /// Its owner starts chats there (cmux#29214), and this Mac never copies the caller's login onto it.
    @Test func aKnownTeammatesMachineSendsNothing() async throws {
        for decision in [Self.decision(outcome: nil, callerOwns: false), Self.decision(requested: nil, harness: "pi", outcome: nil, callerOwns: false)] {
            let run = try await Self.relayChat(decision, link: .team)
            #expect(run.steps == ["login"], "\(decision.summary) was sent")
            let fields = try Self.fields(run.result)
            #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.login_team_machine"))
            #expect(fields["error_message"] == .string(AgentRemoteStartRefusal.teamMachine(machine: "Icon VM").userMessage))
        }
    }

    /// Ownership comes before the login decision, for every agent and when no decision was made: pi (no transfer) and a login
    /// step that decided nothing (the transfer gate off) send only to an owner's machine. A teammate's refuses as one, an
    /// owner nobody read (`unknown`) or no link at all refuses unverified with its command (review21 F1 at 3e900167).
    @Test func ownershipDecidesBeforeTheLoginForEveryAgent() async throws {
        for decision in [nil, Self.decision(harness: "pi", outcome: nil)] {
            let name = decision?.summary ?? "no decision"
            for (link, code) in [(CloudCallerOwnership.team, "cloud.relay.login_team_machine"), (.unknown, "cloud.relay.login_unverified"), (nil, "cloud.relay.login_unverified")] {
                let run = try await Self.relayChat(decision, link: link)
                #expect(run.steps == ["login"], "\(name) on \(link?.rawValue ?? "no link") was sent")
                let fields = try Self.fields(run.result)
                #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string(code), "\(name) on \(link?.rawValue ?? "no link"): \(fields)")
                #expect(fields["command"].map { "\($0)".contains("cmux cloud start-session --target machine:") } == true, "\(name): no recovery command")
            }
            let owned = try await Self.relayChat(decision, link: .owner)
            #expect(owned.steps == ["login", "send"], "\(name) on its owner's machine")
            #expect(try Self.fields(owned.result)["delivered"] == .bool(true))
        }
    }

    /// A Claude skip that keeps the machine's own login sends only when the owner answered: on `unknown` it refuses unverified.
    @Test func aKeptMachineLoginOnAnUnreadOwnerSendsNothing() async throws {
        let kept = Self.decision(outcome: nil, guest: "team", machine: "working")
        try #require(kept.step == .skip && kept.reason == .machineLoginKept)
        let run = try await Self.relayChat(kept, link: .unknown)
        #expect(run.steps == ["login"], "a kept login on an unread owner was sent")
        #expect(try Self.fields(run.result)["error_code"] == .string("cloud.relay.login_unverified"))
    }

    /// A team machine the caller made (the link says owner, its guest says `team`) keeps a working sign-in of its own: sent.
    @Test func aTeamGuestWithItsOwnLoginSends() async throws {
        let kept = Self.decision(outcome: nil, guest: "team", machine: "working")
        try #require(kept.step == .skip && kept.reason == .machineLoginKept && kept.guestKind == "team")
        let run = try await Self.relayChat(kept, link: .owner)
        #expect(run.steps == ["login", "send"])
        #expect(try Self.fields(run.result)["delivered"] == .bool(true))
    }

    /// The same team guest with no sign-in, and none on this Mac to give it: not sent, with the sign-in recovery.
    @Test func aTeamGuestWithNoLoginSendsNothing() async throws {
        let none = Self.decision(outcome: CloudCredentialTransfer.CachedLogin.none.startOutcome, guest: "team")
        try #require(none.guestKind == "team")
        let run = try await Self.relayChat(none, link: .owner)
        #expect(run.steps == ["login"])
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.login_missing"))
    }

    /// A link up whose answer was neither owner nor team (the app server could not read it: `vm_kind: "unknown"`): not a
    /// teammate's machine, and never sent. It is unverified, as with no link at all.
    @Test func anUnreadOwnerAnswerIsUnverifiedNotTeam() async throws {
        let run = try await Self.relayChat(Self.decision(outcome: nil, callerOwns: false), link: .unknown)
        #expect(run.steps == ["login"])
        let fields = try Self.fields(run.result)
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.login_unverified"))
    }

    /// A known owner (its link answered `owner`) whose login was copied: sent.
    @Test func aKnownOwnerWithALoginSends() async throws {
        let run = try await Self.relayChat(Self.decision(outcome: "installed"), link: .owner)
        #expect(run.steps == ["login", "send"])
        #expect(try Self.fields(run.result)["delivered"] == .bool(true))
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

    /// A machine this app made for the signed-in caller passes the ownership check once its link is up; a teammate's or
    /// an unlinked one does not. The check is the link's owner answer, never a guess.
    @Test func anOwnedMachinePassesTheOwnershipCheckOverItsLink() async throws {
        let f = Self.fixture()
        #expect(try await f.services.cloud.callerOwnsVM(f.machine.machineID) == false, "no link: no owner answer")
        _ = try await #require(f.machine.appLink).connect(origin: .script)
        #expect(try await f.services.cloud.callerOwnsVM(f.machine.machineID) == true)
        let theirs = CloudTestLink.session(id: "vm_" + String(repeating: "t", count: 20), name: "Theirs", owns: false, mainWork: f.services.mainWork)
        f.services.machines.add(theirs)
        _ = try await #require(theirs.appLink).connect(origin: .script)
        #expect(try await f.services.cloud.callerOwnsVM(theirs.machineID) == false)
    }

    /// Every typed login refusal of a CLI run carries the start-session command that recovers, the timed-out and
    /// account-changed ones too: the CLI never forwards a null recovery.
    @Test func everyLoginRefusalCarriesItsRecoveryCommand() async throws {
        let runs = [try await Self.relayChat(Self.decision(outcome: CloudCredentialTransfer.CachedLogin.none.startOutcome)),
                    try await Self.relayChat(Self.decision(outcome: "installed"), loginTakes: .seconds(1), loginWithin: .milliseconds(100)),
                    try await Self.relayChat(Self.decision(outcome: "installed"), accountChanges: true),
                    try await Self.relayChat(Self.decision(outcome: nil, callerOwns: false), link: nil),
                    try await Self.relayChat(Self.decision(outcome: nil, callerOwns: false), link: .team)]
        var codes: Set<String> = []
        for run in runs {
            let fields = try Self.fields(run.result)
            guard case .string(let code) = fields["error_code"], case .string(let command) = fields["command"] else {
                Issue.record("a refusal with no code or no recovery command: \(fields)"); continue
            }
            codes.insert(code)
            #expect(code.hasPrefix("cloud.relay.login_") && command.hasPrefix("cmux cloud start-session --target machine:"), "\(code): \(command)")
        }
        #expect(codes == ["cloud.relay.login_missing", "cloud.relay.login_pending", "cloud.relay.login_account_changed",
                          "cloud.relay.login_unverified", "cloud.relay.login_team_machine"])
    }

    /// The default relay request (no `--login`) on a machine with no login, none cached, and no prompt possible: the
    /// refusal names the choices, and its command is not the bare rerun (refused the same way) but `--login none`, which
    /// the rules start with nothing copied, so the chat's Sign in to Claude card signs the machine in. No transfer is granted.
    @Test func aDefaultRequestsRecoveryLeadsToTheSignInCard() async throws {
        let unchosen = Self.decision(requested: nil, outcome: nil)
        try #require(unchosen.refusal == .needsLoginChoice)
        let run = try await Self.relayChat(unchosen)
        #expect(run.steps == ["login"])
        let fields = try Self.fields(run.result)
        #expect(fields["error_code"] == .string("cloud.relay.login_refused") && fields["login_reason"] == .string("needs-login-choice"))
        guard case .string(let command) = fields["command"], case .string(let message) = fields["error_message"] else { Issue.record("\(fields)"); return }
        #expect(command.hasSuffix(" --login none") && message.contains("--login machine") && message.contains("--login none"), "\(command) / \(message)")
        // The suggested command, run: start-session's headless start with `--login none` goes on, copying nothing.
        var rerun = Self.decision(requested: CloudHarnessLoginDecision.Choice.none, outcome: nil)
        rerun.requestedByPerson = true
        #expect(rerun.step == .skip && rerun.reason == .choseNone && rerun.refusal == nil && !rerun.readsMachine)
        #expect(Self.decision(requested: nil, outcome: nil).refusal == .needsLoginChoice, "the bare rerun is refused again")
    }

    /// A cold machine: running, no start-session first, no link up. The relay chat's own link step connects it, the login
    /// step then reads the link's owner answer (the app's ownership check, not a stand-in), and only then is the prompt sent.
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
                                        steps: .init(login: { [cloud = f.services.cloud] machine, _, still in
                                            let owns = try await cloud.callerOwnsVM(machine.machineID)
                                            Steps.shared.append(owns ? "login as owner" : "login unverified")
                                            machine.harnessLogin = Self.decision(outcome: owns ? "installed" : nil, callerOwns: owns)
                                            try still()
                                        }, relay: { Self.relay }))
        let invoke = try #require(f.services.registry.action(for: "cloudRelayChat")?.invoke)
        let run = f.services.registry.capturingRun { invoke(Self.invocation(f.machine)) }
        let fields = try Self.fields(await run.results.first?.value)
        return (fields, Steps.shared.take())
    }

    @Test func aColdMachineConnectsThenLogsInAsItsOwnerThenSends() async throws {
        let f = Self.cold { Steps.shared.append("connect") }
        defer { f.machine.disconnect() }
        #expect(await f.machine.appLink?.currentLinkSocket == nil && f.machine.harnessLogin == nil, "not cold")
        let run = try await Self.coldRun(f)
        #expect(run.steps == ["connect", "login as owner", "send"])
        #expect(run.fields["delivered"] == .bool(true) && f.machine.harnessLogin?.callerOwns == true)
    }

    /// A cold machine whose link never comes up: no login step, nothing sent, and an undelivered code that is not a `login_`
    /// one, so `cloud start-chat` runs start-session on the machine (it resumes, waits and connects); its command says the same.
    @Test func aColdMachineThatDoesNotConnectSendsNothing() async throws {
        let f = Self.cold { Steps.shared.append("connect"); throw CloudLinkError.disconnected(reason: "link down") }
        defer { f.machine.disconnect() }
        let run = try await Self.coldRun(f)
        #expect(run.steps == ["connect"])
        #expect(run.fields["delivered"] == .bool(false) && run.fields["error_code"] == .string("cloud.relay.not_connected"))
        guard case .string(let command) = run.fields["command"] else { Issue.record("no recovery command"); return }
        #expect(command.hasPrefix("cmux cloud start-session --target machine:"))
    }

    /// A cold paused machine, and a cold one resuming (`starting`): this entry neither connects nor logs in nor sends. It answers
    /// `machine_not_ready` with the start-session command, which resumes or waits out the machine, then connects and logs in;
    /// `cloud start-chat` runs that itself on this code (any undelivered code that isn't a `login_` one).
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

    /// A cold machine whose record status is not known yet (`.unknown`, before any list read): the script connect does not
    /// connect a machine that isn't live, so no connect, no login and no send; `not_connected` (start-chat's start-session way).
    @Test func aColdMachineOfUnknownStatusSendsNothing() async throws {
        let f = Self.cold(.unknown) { Steps.shared.append("connect") }
        defer { f.machine.disconnect() }
        let run = try await Self.coldRun(f)
        #expect(run.steps == [], "\(run.steps)")
        #expect(run.fields["delivered"] == .bool(false) && run.fields["error_code"] == .string("cloud.relay.not_connected"))
        guard case .string(let command) = run.fields["command"] else { Issue.record("no recovery command"); return }
        #expect(command.hasPrefix("cmux cloud start-session --target machine:" + f.machine.machineID), "\(command)")
    }

    /// The signed-in account a test switches while the link step waits.
    nonisolated final class Account: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String?] = ["user-1", "team-A"]
        var now: [String?] { lock.withLock { value } }
        func switchTo(_ account: [String?]) { lock.withLock { value = account } }
    }

    /// Runs a CLI relay chat whose link step is `link` and whose account is `account`; the login and send are recorded.
    static func linkRun(account: Account, loginWithin: Duration = CloudStartSession.loginWithin,
                        link: @escaping @MainActor (CloudMachineSession) async -> Bool) async throws -> [String: ActionResultValue] {
        let f = fixture()
        defer { f.machine.disconnect() }
        _ = Steps.shared.take()
        CloudStartSession.bindRelayChat(into: f.services.registry, context: AppActionContext(services: f.services), reason: { nil },
                                        steps: .init(login: { machine, _, still in
                                            Steps.shared.append("login")
                                            machine.harnessLogin = Self.decision(outcome: "installed")
                                            try still()
                                        }, relay: { Self.relay }, loginWithin: loginWithin, link: link, account: { account.now }))
        let invoke = try #require(f.services.registry.action(for: "cloudRelayChat")?.invoke)
        let run = f.services.registry.capturingRun { invoke(Self.invocation(f.machine)) }
        return try Self.fields(await run.results.first?.value)
    }

    /// The account changes while the link step is suspended: once the link answers, no login starts (it would read the new
    /// account's user and team), nothing is sent, and the run answers `login_account_changed`.
    @Test func anAccountChangeWhileTheLinkWaitsStartsNoLogin() async throws {
        let account = Account()
        let (held, release) = AsyncStream.makeStream(of: Void.self)
        // task-owner: switches the account while the link step is held, then lets the link answer
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            account.switchTo(["user-2", "team-B"])
            release.yield()
        }
        let fields = try await Self.linkRun(account: account) { _ in
            Steps.shared.append("link")
            for await _ in held { break }
            return true
        }
        #expect(Steps.shared.take() == ["link"], "a login or send ran for another account")
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.login_account_changed"))
    }

    /// The link answers after the run's `loginWithin` ran out: the run has already answered `login_pending` (the deadline's
    /// code, the account being unchanged), and the link's late answer starts no login and sends nothing.
    @Test func aLinkThatAnswersAfterTheDeadlineStartsNoLogin() async throws {
        let fields = try await Self.linkRun(account: Account(), loginWithin: .milliseconds(100)) { _ in
            Steps.shared.append("link")
            try? await Task.sleep(for: .milliseconds(400))
            return true
        }
        #expect(fields["delivered"] == .bool(false) && fields["error_code"] == .string("cloud.relay.login_pending"))
        try await Task.sleep(for: .seconds(1))
        #expect(Steps.shared.take() == ["link"], "the late link started a login or a send")
    }

    /// The person's own run (the palette) sees the same refusal, and nothing is sent.
    @Test func thePersonsRunIsRefusedTheSameWay() async throws {
        let run = try await Self.relayChat(Self.decision(outcome: CloudCredentialTransfer.CachedLogin.none.startOutcome), origin: .user)
        #expect(run.steps == ["login"])
        let failure = try #require(run.work ?? nil, "the person's refused relay chat answered no failure")
        #expect(failure.message.contains("Sign in to Claude") || failure.shownReason?.contains("Sign in to Claude") == true, "\(failure)")
    }

    /// No answer field carries the bearer the relay used.
    @Test func noAnswerCarriesTheAccessToken() async throws {
        for decision in [Self.decision(outcome: "installed"), Self.decision(outcome: CloudCredentialTransfer.CachedLogin.none.startOutcome), Self.decision(requested: nil, outcome: nil)] {
            let fields = try Self.fields(try await Self.relayChat(decision).result)
            #expect(!fields.values.contains { "\($0)".contains("fixture-access") })
        }
    }
}
