import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextOnboarding
import Foundation
import Testing

/// The onboarding page's host: the state is readable at any time, and a gesture runs only on a
/// real click or key in the page, once per click or key.
@MainActor @Suite struct OnboardingPageProviderTests {
    private func make(step: OnboardingModel.Step = .agents) -> (OnboardingModel, OnboardingPageProvider) {
        let model = OnboardingModel(services: MockOnboardingServices(), step: step)
        return (model, OnboardingPageProvider(model: model))
    }

    private func context(gesture: TimeInterval?) -> PageCallContext {
        PageCallContext(page: "cmux.onboarding", userGesture: gesture != nil, gestureEvent: gesture)
    }

    @Test func theStateNeedsNoGesture() async throws {
        let (_, provider) = make()
        let state = try await provider.call("cmux.onboarding.state", params: [:], context: context(gesture: nil))
        #expect(state["step"]?.stringValue == "agents")
        #expect(state["footer"]?["primary"]?.stringValue == "continue")
    }

    @Test func aGestureWithoutAClickIsRefused() async {
        let (model, provider) = make()
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.onboarding.skip", params: [:], context: context(gesture: nil))
        }
        #expect(!model.ended, "nothing the page sends on its own ends the window")
    }

    @Test func oneClickRunsOneGesture() async throws {
        let (model, provider) = make(step: .importData)
        _ = try await provider.call("cmux.onboarding.import.toggleKeepInSync", params: [:], context: context(gesture: 100))
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.onboarding.skip", params: [:], context: context(gesture: 100))
        }
        #expect(!model.ended, "a second op off the same click is refused")
        _ = try await provider.call("cmux.onboarding.skip", params: [:], context: context(gesture: 101))
        #expect(model.ended, "the next click runs")
    }
}
