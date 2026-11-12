import CmuxNextAgentIntegrations
@testable import CmuxNextOnboarding
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The cmux Tools step: cmux asks before it adds its MCP server (Computer Use included) to the
/// person's coding agents. Nothing is written until the person answers; Add to My Agents sets
/// `agents.cmuxMcp` to `on` before `cmux setup mcp` runs (the CLI reads it), Not Now sets `off` and
/// runs nothing, and first run asks only while nobody answered and an agent is there to ask about.
@MainActor @Suite(.serialized) struct OnboardingAgentToolsStepTests {
    /// The app's source, recorded: the settings write and each `cmux setup mcp` run, in order.
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
            return agents
        }
        func applyAgentTools(remove: Bool) async -> [AgentToolsAgent]? {
            calls.append(remove ? "remove" : "add with \(choice.rawValue)")
            agents = agents.map { AgentToolsAgent(id: $0.id, name: $0.name, state: $0.state == .conflict ? .conflict : remove ? .ready : .added) }
            return agents
        }
    }

    private static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: The report `cmux setup mcp` prints

    @Test func theSetupReportListsInstalledAgentsWithWhatTheirConfigHolds() throws {
        let report = """
        {"state": "needs_user", "clients": [
          {"id": "claude", "name": "Claude Code", "installed": true, "state": "ok", "user_action": null},
          {"id": "codex", "name": "Codex", "installed": true, "state": "needs_user", "user_action": {"kind": "conflict"}},
          {"id": "gemini", "name": "Gemini", "installed": false, "state": "not_applicable"}
        ]}
        """
        let agents = try #require(AgentToolsAgent.agents(setupReport: Data(report.utf8)))
        #expect(agents == [AgentToolsAgent(id: "claude", name: "Claude Code", state: .added),
                           AgentToolsAgent(id: "codex", name: "Codex", state: .conflict)])
        let planned = #"{"clients": [{"id": "codex", "name": "Codex", "installed": true, "state": "planned"}, {"id": "claude", "name": "Claude Code", "installed": true, "state": "failed"}]}"#
        #expect(AgentToolsAgent.agents(setupReport: Data(planned.utf8))?.map(\.state) == [.ready, .failed])
        // `--remove`: `changed` took cmux out.
        let removed = #"{"action": "remove", "clients": [{"id": "codex", "name": "Codex", "installed": true, "state": "changed"}]}"#
        #expect(AgentToolsAgent.agents(setupReport: Data(removed.utf8), removing: true)?.map(\.state) == [.ready])
        #expect(AgentToolsAgent.agents(setupReport: Data("not json".utf8)) == nil)
    }

    // MARK: The step

    @Test func addAnswersYesBeforeTheCLIRunsAndNotNowWritesNothingToAnyAgent() async {
        let yes = Source()
        let add = AgentToolsStepModel(source: yes)
        add.start()
        await Self.until { add.loaded }
        #expect(yes.calls == ["read"], "showing the step reads only")
        add.add()
        await Self.until { !add.applying && add.addedCount == 2 }
        #expect(yes.calls == ["read", "set on", "add with on"], "the answer reaches the settings file before setup mcp reads it")
        #expect(add.answered && add.choice == .on && !add.failed)

        let no = Source()
        let decline = AgentToolsStepModel(source: no)
        decline.start()
        await Self.until { decline.loaded }
        decline.decline()
        await Self.until { no.calls.count == 2 }
        #expect(no.calls == ["read", "set off"], "Not Now runs no setup mcp")
        #expect(decline.answered && decline.choice == .off)
    }

    /// The answer must reach the settings file before `cmux setup mcp` reads it: a refused write runs no
    /// CLI and shows as failed, never as added.
    @Test func aRefusedAnswerRunsNothingAndSaysSo() async {
        let source = Source()
        source.writes = false
        let model = AgentToolsStepModel(source: source)
        model.start()
        await Self.until { model.loaded }
        model.add()
        await Self.until { !model.applying && model.failed }
        #expect(source.calls == ["read", "set on"], "no setup mcp after a refused write")
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

    @Test func aServerOfThePersonsNamedCmuxMarksTheRunAsNotComplete() async {
        let source = Source(agents: [AgentToolsAgent(id: "claude", name: "Claude Code", state: .ready),
                                     AgentToolsAgent(id: "codex", name: "Codex", state: .conflict)])
        let model = AgentToolsStepModel(source: source)
        model.start()
        await Self.until { model.loaded }
        model.add()
        await Self.until { !model.applying && model.addedCount == 1 }
        #expect(model.failed)
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

    // MARK: First run

    @Test func firstRunAsksOnlyWhileNobodyAnsweredAndAnAgentIsThere() async {
        func presenter() -> (OnboardingWindowPresenter, () -> [OnboardingModel.Step]) {
            var shown: [OnboardingModel.Step] = []
            let presenter = OnboardingWindowPresenter(makeModel: { step in OnboardingModel(services: MockOnboardingServices(), step: step) },
                                                      activeLook: nil, present: { shown.append($0.model.step) })
            return (presenter, { shown })
        }
        let (asks, asked) = presenter()
        await asks.showAgentToolsAtFirstRun(isFirstRun: true, source: Source())
        #expect(asked() == [.agentTools])
        for (isFirstRun, source) in [(false, Source()), (true, Source(choice: .on)), (true, Source(choice: .off)), (true, Source(agents: []))] {
            let (quiet, shown) = presenter()
            await quiet.showAgentToolsAtFirstRun(isFirstRun: isFirstRun, source: source)
            #expect(shown().isEmpty, "first run \(isFirstRun), answer \(source.choice), \(source.agents.count) agents")
        }
        let (none, shown) = presenter()
        await none.showAgentToolsAtFirstRun(isFirstRun: true, source: nil)
        #expect(shown().isEmpty)
    }

    // MARK: The Set Up cmux card

    /// The card's row asks while nobody answered and an agent is found; Add runs setup mcp, Not Now does not;
    /// either answer finishes the row. Answered before, or no agent: no row, and the card does not wait on it.
    @Test func theSetUpCardRowAsksOnceAndEitherAnswerFinishesIt() async throws {
        let suite = "cmux-agent-tools-card-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let setup = FirstRunSetup(defaults: defaults)
        func environment(_ tools: Source?) -> SetupCardEnvironment {
            SetupCardEnvironment(account: { (false, nil) }, signInAccount: {}, cliState: { "missing" }, installCLI: { _ in },
                                 openAgents: {}, screenReader: { false }, historySources: { false }, importHistory: { false },
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
        #expect(yes.calls == ["read", "set on", "add with on"])
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
