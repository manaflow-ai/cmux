import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextOnboarding
import Foundation
import Testing

/// Make cmux Yours (cmux#48416), the first run's one setup screen: it reads the person's settings,
/// writes only what they change (each pick at once, as a change from what was set), refuses a
/// background it does not offer, and takes its picks only from the page's own ops on its own step.
@MainActor @Suite(.serialized) struct OnboardingMakeItYoursStepTests {
    @MainActor final class Source: FirstRunChoicesSource {
        var current: FirstRunChoices
        var applied: [(new: FirstRunChoices, old: FirstRunChoices)] = []

        init(_ current: FirstRunChoices = .recommended) { self.current = current }

        func currentChoices() -> FirstRunChoices { current }
        func backgrounds() async -> [FirstRunBackground] {
            [FirstRunBackground(id: "daily", name: ""), FirstRunBackground(id: "hogai-nio", name: "Nio")]
        }
        func apply(_ new: FirstRunChoices, from old: FirstRunChoices) {
            applied.append((new, old))
            current = new
        }
    }

    private static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func clicked(_ event: TimeInterval) -> PageCallContext {
        PageCallContext(page: "cmux.onboarding", userGesture: true, gestureEvent: event)
    }

    @Test func showingTheStepReadsTheSettingsAndWritesNothing() async {
        let source = Source(FirstRunChoices(workStyle: .terminal, density: .compact, background: "daily"))
        let step = MakeItYoursStepModel(source: source)
        step.start()
        await Self.until { step.loaded }
        #expect(step.choices == source.current)
        #expect(step.backgrounds.map(\.id) == ["daily", "hogai-nio"])
        #expect(source.applied.isEmpty)
    }

    @Test func eachPickWritesOnlyItsChangeAndAnUnknownBackgroundIsRefused() async {
        let source = Source()
        let step = MakeItYoursStepModel(source: source)
        step.start()
        await Self.until { step.loaded }
        step.setDensity(.standard)
        #expect(source.applied.isEmpty, "the answer already set writes nothing")
        step.setWorkStyle(.terminal)
        #expect(source.applied.last?.old.workStyle == .gui)
        #expect(source.applied.last?.new.workStyle == .terminal)
        #expect(step.setBackground("hogai-nio"))
        #expect(!step.setBackground("not-offered"))
        #expect(step.choices.background == "hogai-nio", "a refused id changes nothing")
        #expect(step.setBackground(nil))
        #expect(source.applied.map(\.new.background) == [nil, "hogai-nio", nil])
    }

    /// Skip puts back what was set when the step opened, in one write; with nothing picked it writes nothing.
    @Test func skipPutsBackTheOpeningChoices() async {
        let opening = FirstRunChoices(workStyle: .terminal, density: .compact, background: "daily")
        let source = Source(opening)
        let step = MakeItYoursStepModel(source: source)
        step.start()
        await Self.until { step.loaded }
        step.revert()
        #expect(source.applied.isEmpty, "nothing picked, nothing written")
        step.setWorkStyle(.gui)
        step.setDensity(.comfortable)
        #expect(step.setBackground("hogai-nio"))
        step.revert()
        #expect(source.current == opening)
        #expect(step.choices == opening)
        #expect(source.applied.count == 4, "three picks and one write back")
        #expect(source.applied.last?.old == FirstRunChoices(workStyle: .gui, density: .comfortable, background: "hogai-nio"))
    }

    @Test func skippingTheStepPutsBackTheOpeningChoices() async {
        let opening = FirstRunChoices(workStyle: .terminal, density: .compact, background: nil)
        let source = Source(opening)
        let model = OnboardingModel(services: MockOnboardingServices(), step: .makeItYours, choices: source)
        model.stepDidAppear()
        await Self.until { model.makeItYours.loaded }
        model.makeItYours.setWorkStyle(.gui)
        model.skipStep()
        #expect(source.current == opening)
    }

    @Test func thePagesOpsSetTheChoicesOnTheirStepOnly() async throws {
        let source = Source()
        let model = OnboardingModel(services: MockOnboardingServices(), step: .makeItYours, choices: source)
        let provider = OnboardingPageProvider(model: model)
        model.stepDidAppear()
        await Self.until { model.makeItYours.loaded }
        let state = try await provider.call("cmux.onboarding.state", params: [:], context: PageCallContext(page: "cmux.onboarding"))
        #expect(state["step"]?.stringValue == "makeItYours")
        #expect(state["makeItYours"]?["workStyle"]?.stringValue == "gui")
        #expect(state["makeItYours"]?["background"] == .null)
        #expect(state["footer"]?["primary"]?.stringValue == "continue")

        _ = try await provider.call("cmux.onboarding.makeItYours.workStyle", params: ["value": "terminal"], context: clicked(300))
        _ = try await provider.call("cmux.onboarding.makeItYours.density", params: ["value": "comfortable"], context: clicked(301))
        _ = try await provider.call("cmux.onboarding.makeItYours.background", params: ["id": "daily"], context: clicked(302))
        #expect(source.current == FirstRunChoices(workStyle: .terminal, density: .comfortable, background: "daily"))
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.onboarding.makeItYours.background", params: ["id": "elsewhere"], context: clicked(303))
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.onboarding.makeItYours.density", params: ["value": "huge"], context: clicked(304))
        }
        _ = try await provider.call("cmux.onboarding.makeItYours.background", params: ["id": .null], context: clicked(305))
        #expect(source.current.background == nil, "null is no background")

        let other = OnboardingPageProvider(model: OnboardingModel(services: MockOnboardingServices(), step: .agents, choices: Source()))
        await #expect(throws: PageError.self) {
            _ = try await other.call("cmux.onboarding.makeItYours.workStyle", params: ["value": "terminal"], context: clicked(306))
        }
    }

    /// Once per install and only on a first run: an upgrade marks it and never shows it.
    @Test func theStepShowsOnceOnAFirstRunAndNeverOnAnUpgrade() async throws {
        var shown: [OnboardingModel.Step] = []
        let presenter = OnboardingWindowPresenter(makeModel: { OnboardingModel(services: MockOnboardingServices(), step: $0, choices: Source()) },
                                                  activeLook: nil, present: { shown.append($0.model.step) })
        let upgraded = try #require(UserDefaults(testSuiteName: "cmux-make-yours-\(UUID().uuidString)"))
        await presenter.showMakeItYoursAtFirstRun(isFirstRun: false, defaults: upgraded)
        #expect(shown.isEmpty && upgraded.bool(forKey: OnboardingWindowPresenter.makeItYoursShownKey))
        await presenter.showMakeItYoursAtFirstRun(isFirstRun: true, defaults: upgraded)
        #expect(shown.isEmpty, "a later launch that looks like a first run still skips it")

        let fresh = try #require(UserDefaults(testSuiteName: "cmux-make-yours-\(UUID().uuidString)"))
        await presenter.showMakeItYoursAtFirstRun(isFirstRun: true, defaults: fresh)
        #expect(shown == [.makeItYours])
        await presenter.showMakeItYoursAtFirstRun(isFirstRun: true, defaults: fresh)
        #expect(shown == [.makeItYours], "once per install")
    }

    /// The step's three densities over the setting's five: the extremes read as their neighbor, and
    /// Standard writes the default preset.
    @Test func densityMapsOntoTheSettingsPresets() {
        #expect(FirstRunChoicesSettingsSource.density("ultraCompact") == .compact)
        #expect(FirstRunChoicesSettingsSource.density("cozy") == .standard)
        #expect(FirstRunChoicesSettingsSource.density(nil) == .standard)
        #expect(FirstRunChoicesSettingsSource.density("spacious") == .comfortable)
        #expect(DensityChoice.allCases.map(FirstRunChoicesSettingsSource.preset) == ["compact", "cozy", "comfortable"])
    }
}
