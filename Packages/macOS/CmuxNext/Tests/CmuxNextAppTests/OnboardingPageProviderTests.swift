import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextOnboarding
import Foundation
import Testing

/// The onboarding page's host: the state is readable at any time and keeps the protocol's nulls,
/// a gesture runs without a key or mouse event (VoiceOver presses a control without one), and a
/// missing agent cmux can install is a row with its Install.
@MainActor @Suite struct OnboardingPageProviderTests {
    private func make(step: OnboardingModel.Step = .agents) -> (OnboardingModel, OnboardingPageProvider) {
        let model = OnboardingModel(services: MockOnboardingServices(), step: step)
        return (model, OnboardingPageProvider(model: model))
    }

    /// A call as VoiceOver's press makes it: no key or mouse event behind it.
    private let pressed = PageCallContext(page: "cmux.onboarding")

    @Test func theStateKeepsItsNulls() async throws {
        let (_, provider) = make()
        let state = try await provider.call("cmux.onboarding.state", params: [:], context: pressed)
        #expect(state["step"]?.stringValue == "agents")
        #expect(state["footer"]?["primary"]?.stringValue == "continue")
        #expect(state["footer"]?["progress"] == .null, "a T | null field is sent as null, not left out")
        #expect(state["importer"] == .null)
        #expect(state["agents"]?["signingIn"] == .null)
    }

    @Test func aPressWithoutAKeyOrMouseEventRuns() async throws {
        let (model, provider) = make()
        _ = try await provider.call("cmux.onboarding.skip", params: [:], context: pressed)
        #expect(model.ended, "VoiceOver's press on Skip ends the window, as the AppKit button did")
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

        _ = try await provider.call("cmux.onboarding.agents.install", params: ["id": "claude"], context: pressed)
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
        let state = try await provider.call("cmux.onboarding.state", params: [:], context: pressed)
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
            _ = try await provider.call("cmux.onboarding.import.toggleProfile", params: ["id": "nope"], context: pressed)
        }
    }
}
