import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextOnboarding
import Foundation
import Testing

/// The onboarding page's host: the state is readable at any time and keeps the protocol's nulls,
/// and a gesture runs without a key or mouse event (VoiceOver presses a control without one).
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

    @Test func anUnknownProfileIsRefused() async {
        let (_, provider) = make(step: .importData)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.onboarding.import.toggleProfile", params: ["id": "nope"], context: pressed)
        }
    }
}
