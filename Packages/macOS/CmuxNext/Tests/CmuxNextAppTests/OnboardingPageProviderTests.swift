import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextOnboarding
import Foundation
import Testing

/// The onboarding page's host: the state is readable at any time and keeps the protocol's nulls,
/// a gesture runs only on its own click or key (a page script alone runs nothing, and one click
/// runs one gesture, on its own step only), and a missing agent cmux can install is a row with its Install.
@MainActor @Suite struct OnboardingPageProviderTests {
    private func make(step: OnboardingModel.Step = .agents) -> (OnboardingModel, OnboardingPageProvider) {
        let model = OnboardingModel(services: MockOnboardingServices(), step: step)
        return (model, OnboardingPageProvider(model: model))
    }

    /// A call with no key or mouse event behind it: what a page script sends on its own.
    private let scripted = PageCallContext(page: "cmux.onboarding")

    /// A call on the person's click or key at `event` (`systemUptime`), as PageRouter records it.
    private func clicked(_ event: TimeInterval) -> PageCallContext {
        PageCallContext(page: "cmux.onboarding", userGesture: true, gestureEvent: event)
    }

    @Test func theStateKeepsItsNulls() async throws {
        let (_, provider) = make()
        let state = try await provider.call("cmux.onboarding.state", params: [:], context: scripted)
        #expect(state["step"]?.stringValue == "agents")
        #expect(state["footer"]?["primary"]?.stringValue == "continue")
        #expect(state["footer"]?["progress"] == .null, "a T | null field is sent as null, not left out")
        #expect(state["importer"] == .null)
        #expect(state["agents"]?["signingIn"] == .null)
    }

    @Test func aCallWithoutAClickOrKeyIsRefused() async {
        let (model, provider) = make()
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.onboarding.skip", params: [:], context: scripted)
        }
        #expect(!model.ended, "a page script alone cannot end the window")
    }

    /// Back from a Sign In, the page's focus rechecks the sign-ins: a click into the page keys the
    /// page engine's child window, which the onboarding window's own didBecomeKey does not see.
    @Test func thePagesFocusRechecksTheSignInsAfterASignIn() async throws {
        let services = MockOnboardingServices()
        let source = MockAgentSignInSource(agents: [OnboardingAgent(id: "codex", name: "Codex", brand: "openai", auth: .signedOut)])
        services.agentSource = source
        let model = OnboardingModel(services: services, step: .agents)
        let provider = OnboardingPageProvider(model: model)
        model.stepDidAppear()
        await Self.until { model.agents.loaded }
        _ = try await provider.call("cmux.onboarding.focused", params: [:], context: scripted)
        #expect(source.reads == [false], "no Sign In yet: focus reads nothing")
        _ = try await provider.call("cmux.onboarding.agents.signIn", params: ["id": "codex"], context: clicked(50))
        await Self.until { source.signIns == ["codex"] }
        _ = try await provider.call("cmux.onboarding.focused", params: [:], context: scripted)
        await Self.until { source.reads.count == 2 }
        #expect(source.reads == [false, true], "after a Sign In, focus checks the sign-ins again")
    }

    @Test func oneClickRunsOneGesture() async throws {
        let (model, provider) = make()
        _ = try await provider.call("cmux.onboarding.skip", params: [:], context: clicked(10))
        #expect(model.ended, "Skip on its own click ends the window")
        let (_, second) = make(step: .importData)
        _ = try await second.call("cmux.onboarding.import.toggleKeepInSync", params: [:], context: clicked(20))
        await #expect(throws: PageError.self) {
            _ = try await second.call("cmux.onboarding.import.toggleKeepInSync", params: [:], context: clicked(20))
        }
    }

    /// A step's own op runs only while the window shows that step: one real click on another
    /// step's window cannot start an import, a grant or an install there.
    @Test func eachStepsOpsAreRefusedOnTheOtherSteps() async throws {
        let ops: [(OnboardingModel.Step, String, JSONValue)] = [
            (.agents, "cmux.onboarding.agents.install", ["id": "claude"]),
            (.agents, "cmux.onboarding.agents.signIn", ["id": "codex"]),
            (.importData, "cmux.onboarding.import.openFullDiskAccess", [:]),
            (.importData, "cmux.onboarding.import.fromFiles", [:]),
            (.importData, "cmux.onboarding.import.passwordsCSV", [:]),
            (.computerUse, "cmux.onboarding.computerUse.allow", ["pane": "accessibility"]),
            (.computerUse, "cmux.onboarding.computerUse.restart", [:]),
        ]
        var event: TimeInterval = 100
        for (own, op, params) in ops {
            for step in OnboardingModel.Step.allCases where step != own {
                let (_, provider) = make(step: step)
                event += 1
                let context = clicked(event)
                await #expect(throws: PageError.self, "\(op) on the \(step) step") {
                    _ = try await provider.call(op, params: params, context: context)
                }
            }
            #expect(OnboardingPageProvider.step(of: op) == own)
        }
        #expect(OnboardingPageProvider.step(of: "cmux.onboarding.next") == nil, "Next, Skip and Back are every step's")
    }

    /// Leo (2026-11-06): offer, never auto-install. The missing agent is a row with Install at rest
    /// and the vendor's page; the page's Install press runs the installer, then the row is the
    /// installed agent's, with no Install.
    @Test func aMissingAgentIsARowWithItsInstall() async throws {
        let services = MockOnboardingServices()
        let source = MockAgentSignInSource(agents: [
            OnboardingAgent(id: "claude", name: "Claude Code", brand: "claude", auth: .unknown, installed: false),
            OnboardingAgent(id: "codex", name: "Codex", brand: "openai", auth: .signedIn),
        ])
        services.agentSource = source
        let model = OnboardingModel(services: services, step: .agents)
        let provider = OnboardingPageProvider(model: model)
        model.stepDidAppear()
        await Self.until { model.agents.loaded }
        var rows = try await rowsOf(provider)
        try #require(rows.count == 2)
        #expect(rows[0]["id"]?.stringValue == "codex")
        #expect(rows[0]["install"] == nil, "an installed agent's row has no install field")
        #expect(rows[1]["id"]?.stringValue == "claude")
        #expect(rows[1]["offersSignIn"] == .bool(false))
        #expect(rows[1]["install"]?["state"]?.stringValue == "idle")
        #expect(rows[1]["install"]?["message"] == .null)
        #expect(rows[1]["install"]?["vendorURL"]?.stringValue == "https://docs.anthropic.com/en/docs/claude-code/setup")
        #expect(source.installsRun.isEmpty, "nothing installs until Install is pressed")
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.onboarding.agents.install", params: ["id": "claude"], context: scripted)
        }
        #expect(source.installsRun.isEmpty, "a page script alone installs nothing")

        _ = try await provider.call("cmux.onboarding.agents.install", params: ["id": "claude"], context: clicked(30))
        await Self.until { source.signIns == ["claude"] }
        #expect(source.installsRun == ["claude"])
        rows = try await rowsOf(provider)
        try #require(rows.count == 2)
        #expect(rows[0]["id"]?.stringValue == "claude")
        #expect(rows[0]["install"] == nil)
    }

    @Test func aFailedInstallSaysWhyBesideItsButton() {
        let failed = OnboardingPageState.install(.failed("no network"), page: URL(string: "https://example.com/setup"))
        #expect(failed == .init(state: "failed", message: "no network", vendorURL: "https://example.com/setup"))
        #expect(OnboardingPageState.install(.installing, page: nil).state == "installing")
    }

    private func rowsOf(_ provider: OnboardingPageProvider) async throws -> [JSONValue] {
        let state = try await provider.call("cmux.onboarding.state", params: [:], context: scripted)
        guard case .array(let rows)? = state["agents"]?["rows"] else { return [] }
        return rows
    }

    private static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func anUnknownProfileIsRefused() async {
        let (_, provider) = make(step: .importData)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.onboarding.import.toggleProfile", params: ["id": "nope"], context: clicked(40))
        }
    }
}
