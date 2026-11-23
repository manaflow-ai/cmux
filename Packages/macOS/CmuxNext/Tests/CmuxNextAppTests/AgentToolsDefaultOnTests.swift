import CmuxNextAgentIntegrations
@testable import CmuxNextOnboarding
import CmuxNextPages
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// cmux's tools come with the app: `agents.cmuxMcp` is `on` unless the person turned it off in
/// Settings, and no launch, first-run window or Set Up cmux card asks about it.
@MainActor @Suite(.serialized) struct AgentToolsDefaultOnTests {
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

    // MARK: The setting

    @Test func theChoiceIsOnUnlessThePersonTurnedItOff() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: AgentToolsChoice.path))
        #expect(descriptor.id == "agents.cmuxMcp")
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("agents.cmuxMcp is a choice")
            return
        }
        #expect(choices.map(\.value) == ["on", "off"])
        #expect(choices.map(\.value) == AgentToolsChoice.allCases.map(\.rawValue))
        #expect(descriptor.defaultValue == .string("on"), "cmux's tools come with the app")
        #expect(descriptor.isPaletteExposed)
        #expect(SettingsSchema.agentRefusedKeys["agents.cmuxMcp"] == .userOnly, "an agent must not change cmux's tools for itself")
        // No value, an old `ask` or any other value is the default; only `off` is off (cmux-tui's AgentsCmuxMcp too).
        for value in [nil, "on", "ask", "maybe", ""] { #expect(AgentToolsChoice(settingsValue: value) == .on, "\(value ?? "nil")") }
        #expect(AgentToolsChoice(settingsValue: "off") == .off)
    }

    // MARK: Nothing asks

    /// A default launch shows no window for an existing install; capture builds and `--skip-onboarding`
    /// show nothing; `--onboarding` runs the first-run steps instead. No step asks about cmux's tools.
    @Test func noLaunchAsksAboutCmuxTools() async throws {
        typealias Steps = OnboardingWindowPresenter.LaunchSteps
        #expect(!OnboardingModel.Step.allCases.map(\.rawValue).contains("agentTools"))
        func launch(_ environment: [String: String], _ arguments: [String], showcase: Bool = false)
            async throws -> (shown: [OnboardingModel.Step], firstRun: Bool) {
            var shown: [OnboardingModel.Step] = []
            let presenter = OnboardingWindowPresenter(makeModel: { step in OnboardingModel(services: MockOnboardingServices(), step: step) },
                                                      activeLook: nil, present: { shown.append($0.model.step) })
            let defaults = try #require(UserDefaults(testSuiteName: "cmux-launch-steps-\(UUID().uuidString)"))
            let firstRun = await presenter.showLaunchSteps(Steps(environment: environment, arguments: arguments, showcase: showcase),
                                                           defaults: defaults)
            return (shown, firstRun)
        }
        let plain = try await launch([:], ["/Applications/cmux NIGHTLY.app/Contents/MacOS/cmux"])
        #expect(plain.shown.isEmpty, "a default launch of an existing install shows no window")
        #expect(!plain.firstRun, "and runs no first-run window")
        #expect(Steps(environment: [:], arguments: ["cmux"]) == .standard)
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

    /// The Set Up cmux card has no cmux Tools row, and its tools actions are unknown.
    @Test func theSetUpCardHasNoCmuxToolsRow() async throws {
        let suite = "cmux-agent-tools-card-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let environment = SetupCardEnvironment(account: { (false, nil) }, signInAccount: {}, cliState: { "missing" }, installCLI: { _ in },
                                               openAgents: {}, screenReader: { false })
        let provider = SetupCardPageProvider(setup: FirstRunSetup(defaults: defaults), agents: nil, environment: environment)
        defer { provider.stop() }
        #expect(provider.state["tools"] == nil)
        let click = PageCallContext(page: PageDescriptor.setupCard.id, userGesture: true, gestureEvent: 1)
        await #expect(throws: (any Error).self) {
            _ = try await provider.call("cmux.setup.run", params: ["action": ["kind": "addTools"]], context: click)
        }
    }
}
