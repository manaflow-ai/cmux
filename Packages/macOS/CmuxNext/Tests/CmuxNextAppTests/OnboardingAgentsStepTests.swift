@testable import CmuxNextAccounts
@testable import CmuxNextAgentPane
@testable import CmuxNextOnboarding
import CmuxNextTestSupport
import Foundation
import os
import Testing

/// The first-run Agents step: it comes before import and computer use, lists the installed
/// agent CLIs with acpmux's sign-in state and offers Install for a missing Claude Code or Codex, and its Sign In is Settings' own gesture (the
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
        /// False fails `_acpmux/harnesses` itself.
        var listed = true
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
            fetch: { _ in
                guard await health.listed else { throw AcpmuxRPCError(code: -32000, message: "daemon gone") }
                return rows
            },
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
    /// one, is not "no health". One cmux can install (Claude Code, Codex) is listed as not
    /// installed, for the step's Install; any other stays out.
    @Test func aHealthAnswerWithoutAHarnessListsItOnlyWhenCmuxCanInstallIt() async {
        let (harnesses, _) = await make(health: """
        {"harnesses":[{"id":"codex","path":"/opt/homebrew/bin/codex","version":"0.50.0","auth":"signedIn"}]}
        """)
        let rows = await harnesses.agentSignIns(recheck: false)
        #expect(rows.map(\.id) == ["claude", "codex"])
        #expect(rows.map(\.installed) == [false, true])
        #expect(rows.map(\.offersSignIn) == [false, false], "no Sign In for a CLI that is not here")
        #expect(rows[0].installPage?.host == "docs.anthropic.com")

        let (none, _) = await make(health: #"{"harnesses":[]}"#)
        let found = await none.agentSignIns(recheck: false)
        #expect(found.filter(\.installed).isEmpty, "the check found no agent CLI")
        #expect(found.map(\.id) == ["claude", "codex"], "both are offered to install")
    }

    /// acpmux lists no row for a CLI it neither has configured nor found: a missing Claude Code or
    /// Codex is still offered to install.
    @Test func aCliAcpmuxListsNoRowForIsStillOfferedToInstall() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-onboarding-norow-\(UUID().uuidString)")
        let environment = AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
                                            socketPath: directory.appending(path: "a.sock").path, daemonArguments: [], childEnvironment: [:])
        let harnesses = SettingsHarnesses(environment: { environment },
            fetch: { _ in [.init(id: "claude", kind: "claude-stdio", source: "path")] },
            fetchHealth: { _, _ in Data(#"{"harnesses":[{"id":"claude","path":"/opt/homebrew/bin/claude","auth":"signedIn"}]}"#.utf8) },
            openTerminal: { _ in true },
            accountsCall: { _, _, _ in throw AcpmuxRPCError(code: -32601, message: "method not found") })
        let rows = await harnesses.agentSignIns(recheck: false)
        #expect(rows.map(\.id) == ["claude", "codex"])
        #expect(rows.map(\.installed) == [true, false])
    }

    /// With no answer from the agents service (no acpmux, or a daemon that did not list), nothing
    /// says Claude Code or Codex is missing: the step offers no Install, which would only fail.
    @Test func noListAnswerOffersNoInstall() async {
        let health = Health(#"{"harnesses":[]}"#)
        health.listed = false
        let (unreachable, _) = await make(health: health)
        #expect(await unreachable.agentSignIns(recheck: false).isEmpty)

        let unavailable = SettingsHarnesses(environment: { nil }, fetch: { _ in [] }, fetchHealth: { _, _ in Data() },
                                            openTerminal: { _ in true },
                                            accountsCall: { _, _, _ in throw AcpmuxRPCError(code: -32601, message: "method not found") })
        #expect(await unavailable.agentSignIns(recheck: false).isEmpty)
    }

    /// A read that found Claude Code missing, then a refresh whose list failed: the service is not
    /// answering now, so the old answer offers no Install.
    @Test func aFailedListAfterAMissingAgentOffersNoInstall() async {
        let health = Health(#"{"harnesses":[{"id":"codex","path":"/opt/homebrew/bin/codex","auth":"signedIn"}]}"#)
        let (harnesses, _) = await make(health: health)
        #expect(await harnesses.agentSignIns(recheck: false).contains { !$0.installed })
        health.listed = false
        #expect(await !harnesses.agentSignIns(recheck: false).contains { !$0.installed })
    }

    /// Install runs `acpmux harness install ID --json` and answers acpmux's error message.
    @Test func installRunsTheHarnessInstallAndAnswersItsError() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-onboarding-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appending(path: "acpmux")
        let argv = directory.appending(path: "argv")
        try """
        #!/bin/sh
        echo "$@" > '\(argv.path)'
        [ "$4" = codex ] && exit 0
        echo '{"error":{"message":"Claude Code did not install: offline. Install it from https://docs.anthropic.com/en/docs/claude-code/setup"}}' >&2
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let environment = AcpmuxEnvironment(executable: script, home: directory, socketPath: directory.appending(path: "a.sock").path,
                                            daemonArguments: [], childEnvironment: [:])
        let harnesses = SettingsHarnesses(environment: { environment }, fetch: { _ in [] }, fetchHealth: { _, _ in Data() },
                                          openTerminal: { _ in true },
                                          accountsCall: { _, _, _ in throw AcpmuxRPCError(code: -32601, message: "method not found") })
        #expect(await harnesses.installAgent("codex") == nil)
        #expect(try String(contentsOf: argv, encoding: .utf8) == "--json harness install codex\n")
        let failure = await harnesses.installAgent("claude")
        #expect(failure?.hasPrefix("Claude Code did not install: offline.") == true, "\(failure ?? "nil")")
        #expect(await harnesses.installAgent("gemini") != nil, "only Claude Code and Codex install")
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

    /// A recheck whose harness list fails also leaves no sign-in state showing as current.
    @Test func aRecheckWithNoHarnessListForgetsTheLastHealth() async {
        let health = Health(#"{"harnesses":[{"id":"codex","path":"/opt/homebrew/bin/codex","auth":"signedIn"}]}"#)
        let (harnesses, _) = await make(health: health)
        // Claude Code, not found, is listed ahead as not installed, for Install.
        #expect(await harnesses.agentSignIns(recheck: false).filter(\.installed).map(\.auth) == [.signedIn])
        health.listed = false
        _ = await harnesses.agentSignIns(recheck: true)
        #expect(harnesses.health.isEmpty)
        #expect(!harnesses.healthAnswered)
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
        #expect(rows.filter(\.installed).map(\.auth) == [.signedIn])
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

    private static let missingClaude = [
        OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .unknown, installed: false),
        OnboardingAgent(id: "codex", name: "Codex", brand: "openai", auth: .signedIn),
    ]

    /// Leo (2026-11-06): offer, never auto-install. A missing agent is offered, not installed; its
    /// Install runs the installer and then goes straight to its Sign In.
    @Test func aMissingAgentIsOfferedAndItsInstallGoesStraightToSignIn() async {
        let (model, services) = model(Self.missingClaude)
        model.stepDidAppear()
        await Self.until { model.agents.loaded }
        #expect(model.agents.agents.map(\.id) == ["codex"])
        #expect(model.agents.installable.map(\.id) == ["claude"])
        #expect(services.installsRun.isEmpty, "nothing installs until Install is pressed")
        model.agents.install("codex")
        #expect(services.installsRun.isEmpty, "an installed agent has no Install")
        model.agents.install("claude")
        #expect(model.agents.installs["claude"] == .installing)
        model.agents.install("claude")
        #expect(services.installsRun.count <= 1, "a second press while one runs starts nothing")
        await Self.until { services.signIns == ["claude"] }
        #expect(services.installsRun == ["claude"])
        #expect(model.agents.installs["claude"] == nil)
        #expect(model.agents.installable.isEmpty)
        #expect(model.agents.agents.map(\.id) == ["claude", "codex"])
        #expect(model.agents.signingIn == "claude")
    }

    /// The cards share one agents model: a focus refresh from another card that supersedes the read after an
    /// install still ends that install with its Sign In (manaflow-ai/cmux#39388 review F1).
    @Test func anInstallsSignInSurvivesARefreshThatSupersedesItsRead() async {
        let (model, services) = model([OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .unknown, installed: false)])
        model.stepDidAppear()
        await Self.until { model.agents.loaded }
        #expect(model.agents.installable.map(\.id) == ["claude"])
        services.holdNextRead = true
        model.agents.install("claude")
        await Self.until { services.heldRead != nil }
        model.agents.refresh(recheck: true)
        await Self.until { services.signIns == ["claude"] }
        #expect(services.signIns == ["claude"], "the refresh's read ends the install with its Sign In")
        #expect(model.agents.installs["claude"] == nil)
        services.heldRead?.resume()
        await Self.until { services.reads.count == 3 && !model.agents.loading }
        #expect(services.signIns == ["claude"], "the superseded read starts no second Sign In")
    }

    @Test func aFailedInstallStaysBesideItsButton() async {
        let (model, services) = model(Self.missingClaude)
        services.installFails = "Claude Code did not install: offline. Install it from https://docs.anthropic.com/en/docs/claude-code/setup"
        model.stepDidAppear()
        await Self.until { model.agents.loaded }
        model.agents.install("claude")
        await Self.until { model.agents.installs["claude"] != .installing }
        #expect(model.agents.installs["claude"] == .failed(services.installFails!))
        #expect(model.agents.installable.map(\.id) == ["claude"])
        #expect(services.signIns.isEmpty)
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
            let defaults = try #require(UserDefaults(testSuiteName: suite))
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
        let missing = MockAgentSignInSource(agents: [OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude",
                                                                     auth: .unknown, installed: false)])
        await none.showAgentsAtFirstRun(isFirstRun: true, source: missing, defaults: try defaults())
        #expect(noneShown().isEmpty, "no agent CLI found (only ones to install): nothing opens")
    }

    /// One step at a time: the first-run step after Agents (Bring your history) waits until the
    /// Agents window closed; with no tool window open it goes at once.
    @Test func theNextFirstRunStepWaitsForTheAgentsWindowToClose() async throws {
        @MainActor final class Order { var steps: [String] = [] }
        // No agent CLI: nothing opens, history follows at once.
        let none = Order()
        let empty = OnboardingWindowPresenter(makeModel: { step in OnboardingModel(services: MockOnboardingServices(), step: step) },
                                              activeLook: nil, present: { _ in })
        await empty.showFirstRunSteps(isFirstRun: true, source: MockAgentSignInSource(), defaults: try #require(UserDefaults(testSuiteName: "cmux-no-agents-\(UUID().uuidString)"))) {
            none.steps.append("history")
        }
        #expect(none.steps == ["history"])

        let suite = "cmux-agents-then-history-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let presenter = OnboardingWindowPresenter(makeModel: { step in OnboardingModel(services: MockOnboardingServices(), step: step) },
                                                  activeLook: nil, present: { _ in })

        let order = Order()
        let steps = Task { @MainActor in
            await presenter.showFirstRunSteps(isFirstRun: true, source: MockAgentSignInSource(agents: Self.listed), defaults: defaults) {
                order.steps.append("history")
            }
        }
        await Self.until { presenter.controller != nil }
        order.steps.append("agents")
        for _ in 0..<20 { await Task.yield() }
        #expect(presenter.controller?.model.step == .agents)
        #expect(order.steps == ["agents"], "history waits while the Agents window shows")

        presenter.controller?.close()
        await steps.value
        #expect(order.steps == ["agents", "history"])
        #expect(presenter.controller == nil)
    }
}
