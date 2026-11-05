@testable import CmuxNextAccounts
@testable import CmuxNextAgentPane
@testable import CmuxNextOnboarding
import Foundation
import os
import Testing

/// The first-run Agents step: it comes before import and computer use, lists only installed
/// agent CLIs with acpmux's sign-in state, and its Sign In is Settings' own gesture (the
/// agent's `acpmux harness login` typed into a terminal tab). Continue and Skip both leave.
@MainActor @Suite(.serialized) struct OnboardingAgentsStepTests {
    @MainActor final class Terminal {
        var lines: [String] = []
        /// False: no terminal tab opens (only remote panes, a disconnected daemon).
        var opens = true
    }

    /// The daemon's `_acpmux/harness/health` answer; nil fails the call.
    @MainActor final class Health {
        var answer: String?
        init(_ answer: String?) { self.answer = answer }
    }

    private static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func agentsComesAheadOfImportAndComputerUse() {
        #expect(OnboardingModel.Step.allCases == [.agents, .importData, .computerUse])
    }

    /// `_acpmux/harnesses` rows joined with `_acpmux/harness/health`: a terminal profile, a
    /// harness that cannot start and one the check did not find on this Mac stay out.
    private func make(health: String?) async -> (SettingsHarnesses, Terminal) {
        await make(health: Health(health))
    }

    private func make(health: Health) async -> (SettingsHarnesses, Terminal) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-onboarding-agents-\(UUID().uuidString)")
        let environment = AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
                                            socketPath: directory.appending(path: "a.sock").path, daemonArguments: [], childEnvironment: [:])
        let terminal = Terminal()
        let rows: [AcpmuxHarnessRow] = [
            .init(id: "claude", kind: "claude-stdio", source: "path"),
            .init(id: "codex", kind: "acp", source: "path"),
            .init(id: "gemini", kind: "acp", source: "path"),
            .init(id: "broken", kind: "acp", source: "config", problem: "launcher failed"),
            .init(id: "shell", kind: "terminal", source: "user-file"),
            .init(id: "mine", name: "My Agent", kind: "acp", source: "user-file"),
        ]
        let harnesses = SettingsHarnesses(environment: { environment },
            fetch: { _ in rows },
            fetchHealth: { _, _ in
                guard let answer = await health.answer else { throw AcpmuxRPCError(code: -32601, message: "method not found") }
                return Data(answer.utf8)
            },
            openTerminal: { line in
                guard terminal.opens else { return false }
                terminal.lines.append(line)
                return true
            },
            accountsCall: { _, _, _ in throw AcpmuxRPCError(code: -32601, message: "method not found") })
        return (harnesses, terminal)
    }

    @Test func signInRowsAreTheInstalledHarnessesWithTheirAuth() async {
        let (harnesses, _) = await make(health: """
        {"harnesses":[
          {"id":"claude","path":"/opt/homebrew/bin/claude","version":"2.1.0","auth":"unknown"},
          {"id":"codex","path":"/opt/homebrew/bin/codex","version":"0.50.0","auth":"signedIn"},
          {"id":"gemini","path":null,"version":null,"auth":"unknown","problem":"not installed"},
          {"id":"mine","path":"/usr/local/bin/mine","auth":"expired"}
        ]}
        """)
        let rows = await harnesses.agentSignIns(recheck: false)
        #expect(rows.map(\.id) == ["claude", "codex", "mine"])
        #expect(rows.map(\.name) == ["Claude Code", "Codex", "My Agent"])
        #expect(rows.map(\.auth) == [.unknown, .signedIn, .expired])
        #expect(rows[0].brand != nil)
    }

    @Test func aDaemonWithoutHealthListsEveryHarnessAsUnknown() async {
        let (harnesses, _) = await make(health: nil)
        let rows = await harnesses.agentSignIns(recheck: false)
        #expect(rows.map(\.id) == ["claude", "codex", "gemini", "mine"])
        #expect(rows.allSatisfy { $0.auth == .unknown })
    }

    /// A check that answered with no row for a harness did not find it: an answer, even an empty
    /// one, is not "no health".
    @Test func aHealthAnswerWithoutAHarnessLeavesItOut() async {
        let (harnesses, _) = await make(health: """
        {"harnesses":[{"id":"codex","path":"/opt/homebrew/bin/codex","version":"0.50.0","auth":"signedIn"}]}
        """)
        let rows = await harnesses.agentSignIns(recheck: false)
        #expect(rows.map(\.id) == ["codex"])
        #expect(rows.map(\.auth) == [.signedIn])

        let (none, _) = await make(health: #"{"harnesses":[]}"#)
        #expect(await none.agentSignIns(recheck: false).isEmpty, "the check found no agent CLI")
    }

    /// A recheck with no answer shows sign-in as not checked, never the last check's states; a
    /// plain read with no answer keeps them.
    @Test func aFailedRecheckForgetsTheLastHealth() async {
        let health = Health("""
        {"harnesses":[
          {"id":"claude","path":"/opt/homebrew/bin/claude","version":"2.1.0","auth":"expired"},
          {"id":"codex","path":"/opt/homebrew/bin/codex","version":"0.50.0","auth":"signedIn"}
        ]}
        """)
        let (harnesses, _) = await make(health: health)
        #expect(await harnesses.agentSignIns(recheck: false).map(\.auth) == [.expired, .signedIn])
        health.answer = nil
        #expect(await harnesses.agentSignIns(recheck: false).map(\.auth) == [.expired, .signedIn])
        let rechecked = await harnesses.agentSignIns(recheck: true)
        #expect(rechecked.map(\.id) == ["claude", "codex", "gemini", "mine"])
        #expect(rechecked.allSatisfy { $0.auth == .unknown })
        #expect(harnesses.health.isEmpty)
    }

    @Test func aSignInThatOpensNoTerminalFails() async {
        let (harnesses, terminal) = await make(health: nil)
        _ = await harnesses.agentSignIns(recheck: false)
        terminal.opens = false
        #expect(!(await harnesses.signInAgent("codex")), "no terminal tab: the step must not say to finish signing in")
        #expect(terminal.lines.isEmpty)
    }

    /// The step reads health only: a signed-in Claude login's plan (`claude auth status`, which
    /// may read the login keychain) is Settings' to ask, never first-run onboarding's.
    @Test func theStepNeverAsksClaudeForItsPlan() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-onboarding-plan-\(UUID().uuidString)")
        let environment = AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
                                            socketPath: directory.appending(path: "a.sock").path, daemonArguments: [], childEnvironment: [:])
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let accounts = Data("""
        {"accounts":[{"id":"claude-login","family":"claude","name":"Claude Code login","home":null,"shadowOf":null,
          "signedIn":true,"plan":null,"email":null,"enabled":true,"builtin":true}]}
        """.utf8)
        let harnesses = SettingsHarnesses(environment: { environment },
            fetch: { _ in [.init(id: "claude", kind: "claude-stdio", source: "path")] },
            fetchHealth: { _, _ in Data(#"{"harnesses":[{"id":"claude","path":"/opt/homebrew/bin/claude","auth":"signedIn"}]}"#.utf8) },
            openTerminal: { _ in true },
            accountsCall: { _, method, _ in method == .accounts ? accounts : Data("{}".utf8) },
            claudeStatus: { _, _ in
                asked.withLock { $0 += 1 }
                return Data(#"{"loggedIn":true,"subscriptionType":"max"}"#.utf8)
            })
        let rows = await harnesses.agentSignIns(recheck: true)
        #expect(rows.map(\.auth) == [.signedIn])
        #expect(asked.withLock { $0 } == 0, "onboarding ran claude auth status")
    }

    @Test func signInTypesTheHarnessLoginAndRefusesATerminalProfile() async {
        let (harnesses, terminal) = await make(health: nil)
        _ = await harnesses.agentSignIns(recheck: false)
        #expect(await harnesses.signInAgent("codex"))
        #expect(terminal.lines.count == 1)
        #expect(terminal.lines.first?.hasSuffix("'harness' 'login' '--' 'codex'") == true)
        #expect(!(await harnesses.signInAgent("shell")), "a terminal profile has no sign-in")
        #expect(terminal.lines.count == 1)
    }

    private func model(_ agents: [OnboardingAgent]) -> (OnboardingModel, MockAgentSignInSource) {
        let services = MockOnboardingServices()
        let source = MockAgentSignInSource(agents: agents)
        services.agentSource = source
        return (OnboardingModel(services: services, step: .agents), source)
    }

    private static let listed = [
        OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .unknown),
        OnboardingAgent(id: "codex", name: "Codex", brand: "openai", auth: .signedIn),
    ]

    @Test func theStepListsTheAgentsAndContinueEndsIt() async {
        let (model, services) = model(Self.listed)
        var completed: Bool?
        model.onEnd = { completed = $0 }
        #expect(model.steps == [.agents])
        #expect(model.primaryTitle == OnboardingStrings.continueTitle)
        #expect(model.canAdvance)
        model.stepDidAppear()
        await Self.until { model.agents.loaded }
        #expect(model.agents.agents == Self.listed)
        #expect(services.reads == [false])
        model.next()
        #expect(completed == true)
    }

    @Test func skipEndsTheStepWithoutSigningIn() {
        let (model, services) = model(Self.listed)
        var completed: Bool?
        model.onEnd = { completed = $0 }
        model.stepDidAppear()
        model.skipStep()
        #expect(completed == false)
        #expect(services.signIns.isEmpty)
    }

    @Test func signInRunsOnlyForAnAgentNotSignedInAndTheWindowBecomingKeyRechecks() async {
        let (model, services) = model(Self.listed)
        model.stepDidAppear()
        await Self.until { model.agents.loaded }
        model.windowBecameKey()
        #expect(services.reads == [false], "no Sign In yet: coming back reads nothing")
        model.agents.signIn("codex")
        model.agents.signIn("claude")
        await Self.until { services.signIns.count == 1 }
        #expect(services.signIns == ["claude"])
        #expect(model.agents.signingIn == "claude")
        #expect(!model.agents.signInFailed)
        services.agents = [OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .signedIn), Self.listed[1]]
        model.windowBecameKey()
        await Self.until { services.reads.count == 2 && model.agents.signingIn == nil }
        #expect(services.reads == [false, true])
        #expect(model.agents.signingIn == nil, "signed in now: the step stops asking")
        model.windowBecameKey()
        #expect(services.reads == [false, true])
    }

    @Test func aSignInWithNoTerminalSaysSo() async {
        let (model, services) = model(Self.listed)
        services.signInOpens = false
        model.stepDidAppear()
        await Self.until { model.agents.loaded }
        model.agents.signIn("claude")
        await Self.until { model.agents.signInFailed }
        #expect(model.agents.signInFailed)
    }

    /// First run opens the step once, only with an installed agent CLI; an upgrade never does.
    @Test func firstRunOpensTheStepOnceAndOnlyWithAnAgent() async throws {
        func presenter() -> (OnboardingWindowPresenter, () -> [OnboardingModel.Step]) {
            var shown: [OnboardingModel.Step] = []
            let presenter = OnboardingWindowPresenter(makeModel: { step in OnboardingModel(services: MockOnboardingServices(), step: step) },
                                                      activeLook: nil, present: { shown.append($0.model.step) })
            return (presenter, { shown })
        }
        func defaults() throws -> UserDefaults {
            let suite = "cmux-agents-first-run-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }
        let source = MockAgentSignInSource(agents: Self.listed)

        let first = try defaults()
        let (opens, openShown) = presenter()
        await opens.showAgentsAtFirstRun(isFirstRun: true, source: source, defaults: first)
        await opens.showAgentsAtFirstRun(isFirstRun: true, source: source, defaults: first)
        #expect(openShown() == [.agents], "the step opens once")
        opens.controller?.close()

        let (upgrade, upgradeShown) = presenter()
        let upgraded = try defaults()
        await upgrade.showAgentsAtFirstRun(isFirstRun: false, source: source, defaults: upgraded)
        await upgrade.showAgentsAtFirstRun(isFirstRun: true, source: source, defaults: upgraded)
        #expect(upgradeShown().isEmpty, "an existing installation never gets it")

        let (none, noneShown) = presenter()
        await none.showAgentsAtFirstRun(isFirstRun: true, source: MockAgentSignInSource(), defaults: try defaults())
        await none.showAgentsAtFirstRun(isFirstRun: true, source: nil, defaults: try defaults())
        #expect(noneShown().isEmpty, "no agent CLI found: nothing opens")
    }
}
