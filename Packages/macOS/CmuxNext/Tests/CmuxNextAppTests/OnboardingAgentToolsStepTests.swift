import CmuxNextAgentIntegrations
@testable import CmuxNextOnboarding
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The cmux Tools step: cmux asks whether agents the person starts in cmux get its MCP server
/// (Computer Use included). Nothing is written until the person answers; Turn On sets
/// `agents.cmuxMcp` to `on` and reads the agents again, Not Now sets `off`; neither writes an
/// agent's own config. First run asks only while nobody answered and an agent is there to ask about.
@MainActor @Suite(.serialized) struct OnboardingAgentToolsStepTests {
    /// The app's source, recorded: the settings write and each `cmux setup mcp` read, in order. Its
    /// agents get cmux's tools in cmux once the answer is `on`, as the CLI reports.
    @MainActor final class Source: AgentToolsSource {
        var choice: AgentToolsChoice
        var agents: [AgentToolsAgent]
        var calls: [String] = []

        init(choice: AgentToolsChoice = .ask, agents: [AgentToolsAgent] = Source.found) {
            self.choice = choice
            self.agents = agents
        }

        static let found = [AgentToolsAgent(id: "claude", name: "Claude Code", state: .ready),
                            AgentToolsAgent(id: "codex", name: "Codex", state: .ready)]

        func agentToolsChoice() -> AgentToolsChoice { choice }
        /// False: the settings owner refuses the write (or is not there).
        var writes = true
        func setAgentToolsChoice(_ choice: AgentToolsChoice) async -> Bool {
            calls.append("set \(choice.rawValue)")
            guard writes else { return false }
            self.choice = choice
            return true
        }
        func agentToolsAgents() async -> [AgentToolsAgent] {
            calls.append("read")
            return agents.map { AgentToolsAgent(id: $0.id, name: $0.name, state: choice == .on ? .terminals : $0.state) }
        }
    }

    private static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: The report `cmux setup mcp` prints

    @Test func theSetupReportListsInstalledAgentsAndWhetherTheyGetCmuxTools() throws {
        let report = """
        {"state": "ok", "clients": [
          {"id": "claude", "name": "Claude Code", "installed": true, "state": "terminals", "user_action": null},
          {"id": "codex", "name": "Codex", "installed": true, "state": "planned", "user_action": null},
          {"id": "gemini", "name": "Gemini", "installed": false, "state": "not_applicable"}
        ]}
        """
        let agents = try #require(AgentToolsAgent.agents(setupReport: Data(report.utf8)))
        #expect(agents == [AgentToolsAgent(id: "claude", name: "Claude Code", state: .terminals),
                           AgentToolsAgent(id: "codex", name: "Codex", state: .ready)])
        let failed = #"{"clients": [{"id": "claude", "name": "Claude Code", "installed": true, "state": "failed"}]}"#
        #expect(AgentToolsAgent.agents(setupReport: Data(failed.utf8))?.map(\.state) == [.failed])
        #expect(AgentToolsAgent.agents(setupReport: Data("not json".utf8)) == nil)
    }

    // MARK: The step

    @Test func turnOnAnswersYesThenReadsAndNotNowOnlyAnswers() async {
        let yes = Source()
        let add = AgentToolsStepModel(source: yes)
        add.start()
        await Self.until { add.loaded }
        #expect(yes.calls == ["read"], "showing the step reads only")
        add.add()
        await Self.until { !add.applying && add.addedCount == 2 }
        #expect(yes.calls == ["read", "set on", "read"], "the answer, then a read that shows it")
        #expect(add.answered && add.choice == .on && !add.failed)

        let no = Source()
        let decline = AgentToolsStepModel(source: no)
        decline.start()
        await Self.until { decline.loaded }
        decline.decline()
        await Self.until { no.calls.count == 2 }
        #expect(no.calls == ["read", "set off"], "Not Now only answers")
        #expect(decline.answered && decline.choice == .off)
    }

    /// A refused answer reads nothing more and shows as failed, never as on.
    @Test func aRefusedAnswerRunsNothingAndSaysSo() async {
        let source = Source()
        source.writes = false
        let model = AgentToolsStepModel(source: source)
        model.start()
        await Self.until { model.loaded }
        model.add()
        await Self.until { !model.applying && model.failed }
        #expect(source.calls == ["read", "set on"], "no read after a refused write")
        #expect(model.failed && model.addedCount == 0)
    }

    /// The answer is read live: one given in another window or in Settings shows here at once.
    @Test func anAnswerGivenElsewhereShows() async {
        let source = Source()
        let model = AgentToolsStepModel(source: source)
        model.start()
        await Self.until { model.loaded }
        #expect(model.choice == .ask)
        source.choice = .off
        #expect(model.choice == .off && !model.answered)
    }

    @Test func theWindowsReturnAddsAndItsEscapeDeclinesThenDoneCloses() async throws {
        let services = MockOnboardingServices()
        services.agentToolsSource = Source()
        let model = OnboardingModel(services: services, step: .agentTools)
        var ended: [Bool] = []
        model.onEnd = { ended.append($0) }
        model.stepDidAppear()
        await Self.until { model.agentTools.loaded }
        var page = OnboardingPageState(model: model, images: OnboardingPageImages())
        #expect(page.footer.primary == "addTools" && page.footer.skip == "notNow")
        #expect(page.agentTools?.rows.map(\.state) == ["ready", "ready"])
        #expect(page.agentTools?.choice == "ask")
        model.next()
        await Self.until { !model.agentTools.applying && model.agentTools.addedCount == 2 }
        page = OnboardingPageState(model: model, images: OnboardingPageImages())
        #expect(page.footer.primary == "done" && page.footer.skip == "none")
        #expect(page.agentTools?.answered == true && page.agentTools?.choice == "on")
        #expect(ended.isEmpty, "Add stays, so the rows show what it did")
        model.next()
        #expect(ended == [true])

        let declining = MockOnboardingServices()
        let declined = Source()
        declining.agentToolsSource = declined
        let other = OnboardingModel(services: declining, step: .agentTools)
        other.onEnd = { _ in }
        other.stepDidAppear()
        await Self.until { other.agentTools.loaded }
        other.skipStep()
        await Self.until { declined.calls.contains("set off") }
        #expect(declined.calls == ["read", "set off"])
    }

    /// Not Now before the agents were read (Escape at once) only answers.
    @Test func notNowBeforeTheReadOnlyAnswers() async {
        let source = Source()
        let model = AgentToolsStepModel(source: source)
        model.decline()
        await Self.until { source.calls.contains("set off") && !model.applying }
        #expect(source.calls == ["set off"])
        #expect(model.choice == .off && !model.failed)
    }

    // MARK: First run

    /// The step is asked at launch, a first run or an existing installation (an upgrade too), once
    /// under the launch-only rule: while the answer is not `on`; a yes or an earlier showing keeps
    /// it quiet.
    @Test func launchAsksOnceWhileNobodyAnsweredAndAnAgentIsThere() async throws {
        func presenter() -> (OnboardingWindowPresenter, () -> [OnboardingModel.Step]) {
            var shown: [OnboardingModel.Step] = []
            let presenter = OnboardingWindowPresenter(makeModel: { step in OnboardingModel(services: MockOnboardingServices(), step: step) },
                                                      activeLook: nil, present: { shown.append($0.model.step) })
            return (presenter, { shown })
        }
        func fresh() throws -> UserDefaults {
            try #require(UserDefaults(testSuiteName: "cmux-agent-tools-ask-\(UUID().uuidString)"))
        }
        let defaults = try fresh()
        let (asks, asked) = presenter()
        await asks.askAgentToolsOnce(source: Source(), defaults: defaults)
        #expect(asked() == [.agentTools])
        #expect(defaults.bool(forKey: OnboardingWindowPresenter.agentToolsAskedKey))
        // Closed without an answer: the next launch does not ask again.
        let (again, shownAgain) = presenter()
        await again.askAgentToolsOnce(source: Source(), defaults: defaults)
        #expect(shownAgain().isEmpty)
        // Only a yes keeps it quiet: a no is asked once more under the launch-only rule, and so is a
        // Mac with no coding agent's CLI on the PATH (agent chats need none).
        let (quiet, shownOn) = presenter()
        await quiet.askAgentToolsOnce(source: Source(choice: .on), defaults: try fresh())
        #expect(shownOn().isEmpty)
        for source in [Source(choice: .off), Source(agents: [])] {
            let (asking, shown) = presenter()
            await asking.askAgentToolsOnce(source: source, defaults: try fresh())
            #expect(shown() == [.agentTools], "answer \(source.choice), \(source.agents.count) agents")
        }
        // An install asked under the old rule (its old flag set) is asked once more.
        let upgraded = try fresh()
        upgraded.set(true, forKey: "cmux.onboarding.agentToolsAsked")
        let (again2, shownUpgraded) = presenter()
        await again2.askAgentToolsOnce(source: Source(choice: .off), defaults: upgraded)
        #expect(shownUpgraded() == [.agentTools])
        let (none, shown) = presenter()
        await none.askAgentToolsOnce(source: nil, defaults: try fresh())
        #expect(shown().isEmpty)
    }

    /// First-run onboarding is off by default (Lawrence 2026-11-09), but the cmux Tools question is not a
    /// first-run window: until it is answered, agents cmux starts get no cmux server, so a default launch
    /// (no flag, no env) still asks it once. A teammate's NIGHTLY never asked and its terminals' Codex and
    /// Claude listed no `cmux` (2026-11-19). Capture builds and `--skip-onboarding` ask nothing;
    /// `--onboarding` runs the first-run steps instead.
    @Test func aDefaultLaunchAsksTheCmuxToolsQuestionWithOnboardingOff() async throws {
        typealias Steps = OnboardingWindowPresenter.LaunchSteps
        func launch(_ environment: [String: String], _ arguments: [String], showcase: Bool = false)
            async throws -> (shown: [OnboardingModel.Step], firstRun: Bool) {
            var shown: [OnboardingModel.Step] = []
            let presenter = OnboardingWindowPresenter(makeModel: { step in OnboardingModel(services: MockOnboardingServices(), step: step) },
                                                      activeLook: nil, present: { shown.append($0.model.step) })
            let defaults = try #require(UserDefaults(testSuiteName: "cmux-launch-steps-\(UUID().uuidString)"))
            let firstRun = await presenter.showLaunchSteps(Steps(environment: environment, arguments: arguments, showcase: showcase),
                                                           agentTools: Source(), defaults: defaults)
            return (shown, firstRun)
        }
        let plain = try await launch([:], ["/Applications/cmux NIGHTLY.app/Contents/MacOS/cmux"])
        #expect(plain.shown == [.agentTools], "a default launch asks the cmux Tools question")
        #expect(!plain.firstRun, "and runs no first-run window")
        #expect(Steps(environment: [:], arguments: ["cmux"]).skipsFirstRun, "first-run onboarding stays off")
        for (environment, arguments, showcase) in [(["CMUX_NEXT_SKIP_ONBOARDING": "1"], ["cmux"], false),
                                                   ([:], ["cmux", "--skip-onboarding"], false),
                                                   ([:], ["cmux"], true)] {
            let skipped = try await launch(environment, arguments, showcase: showcase)
            #expect(skipped.shown.isEmpty && !skipped.firstRun, "\(environment) \(arguments) showcase \(showcase)")
        }
        for (environment, arguments) in [(["CMUX_NEXT_ONBOARDING": "1"], ["cmux"]), ([:], ["cmux", "--onboarding"])] {
            let onboarding = try await launch(environment, arguments)
            #expect(onboarding.firstRun && onboarding.shown.isEmpty, "\(environment) \(arguments)")
            #expect(!Steps(environment: environment, arguments: arguments).skipsFirstRun)
        }
    }

    // MARK: The Set Up cmux card

    /// The card's row asks while nobody answered and an agent is found; Turn On answers yes and reads, Not Now answers no;
    /// either answer finishes the row. Answered before, or no agent: no row, and the card does not wait on it.
    @Test func theSetUpCardRowAsksOnceAndEitherAnswerFinishesIt() async throws {
        let suite = "cmux-agent-tools-card-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let setup = FirstRunSetup(defaults: defaults)
        func environment(_ tools: Source?) -> SetupCardEnvironment {
            SetupCardEnvironment(account: { (false, nil) }, signInAccount: {}, cliState: { "missing" }, installCLI: { _ in },
                                 openAgents: {}, screenReader: { false },
                                 agentTools: tools)
        }
        let click = { (at: TimeInterval) in PageCallContext(page: PageDescriptor.setupCard.id, userGesture: true, gestureEvent: at) }

        let yes = Source()
        let provider = SetupCardPageProvider(setup: setup, agents: nil, environment: environment(yes))
        defer { provider.stop() }
        await Self.until { provider.tools.loaded }
        #expect(provider.state["tools"] == ["agents": ["Claude Code", "Codex"], "choice": "ask", "applying": false])
        #expect(!provider.toolsDone)
        _ = try await provider.call("cmux.setup.run", params: ["action": ["kind": "addTools"]], context: click(1))
        await Self.until { !provider.tools.applying && provider.tools.addedCount == 2 }
        #expect(yes.calls == ["read", "set on", "read"])
        #expect(provider.toolsDone && provider.state["tools"]?["choice"] == "on")

        let no = Source()
        let declining = SetupCardPageProvider(setup: setup, agents: nil, environment: environment(no))
        defer { declining.stop() }
        await Self.until { declining.tools.loaded }
        _ = try await declining.call("cmux.setup.run", params: ["action": ["kind": "declineTools"]], context: click(2))
        await Self.until { no.calls.contains("set off") }
        #expect(no.calls == ["read", "set off"] && declining.toolsDone)

        for source in [Source(choice: .on), Source(agents: [])] {
            let quiet = SetupCardPageProvider(setup: setup, agents: nil, environment: environment(source))
            defer { quiet.stop() }
            await Self.until { quiet.tools.loaded }
            #expect(quiet.state["tools"] == .null && quiet.toolsDone)
        }
        let none = SetupCardPageProvider(setup: setup, agents: nil, environment: environment(nil))
        defer { none.stop() }
        #expect(none.state["tools"] == .null && none.toolsDone)
    }

    // MARK: The setting

    @Test func theAnswerIsOneSchemaSettingOnlyThePersonChanges() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: AgentToolsChoice.path))
        #expect(descriptor.id == "agents.cmuxMcp")
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("agents.cmuxMcp is a choice")
            return
        }
        #expect(choices.map(\.value) == AgentToolsChoice.allCases.map(\.rawValue))
        #expect(descriptor.defaultValue == .string("ask"), "unanswered keeps today's behavior")
        #expect(descriptor.isPaletteExposed)
        #expect(SettingsSchema.agentRefusedKeys["agents.cmuxMcp"] == .userOnly, "an agent must not grant itself cmux's tools")
    }
}
