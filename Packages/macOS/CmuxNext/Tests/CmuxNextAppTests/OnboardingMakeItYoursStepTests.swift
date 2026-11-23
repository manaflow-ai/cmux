import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
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
        func apply(_ new: FirstRunChoices, from old: FirstRunChoices) async {
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
        await step.waitForWrites()
        #expect(source.applied.last?.old.workStyle == .gui)
        #expect(source.applied.last?.new.workStyle == .terminal)
        #expect(step.setBackground("hogai-nio"))
        #expect(!step.setBackground("not-offered"))
        #expect(step.choices.background == "hogai-nio", "a refused id changes nothing")
        #expect(step.setBackground(nil))
        await step.waitForWrites()
        #expect(source.applied.map(\.new.background) == [nil, "hogai-nio", nil])
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
        await model.makeItYours.waitForWrites()
        #expect(source.current == FirstRunChoices(workStyle: .terminal, density: .comfortable, background: "daily"))
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.onboarding.makeItYours.background", params: ["id": "elsewhere"], context: clicked(303))
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.onboarding.makeItYours.density", params: ["value": "huge"], context: clicked(304))
        }
        _ = try await provider.call("cmux.onboarding.makeItYours.background", params: ["id": .null], context: clicked(305))
        await model.makeItYours.waitForWrites()
        #expect(source.current.background == nil, "null is no background")

        let other = OnboardingPageProvider(model: OnboardingModel(services: MockOnboardingServices(), step: .agents, choices: Source()))
        await #expect(throws: PageError.self) {
            _ = try await other.call("cmux.onboarding.makeItYours.workStyle", params: ["value": "terminal"], context: clicked(306))
        }
    }

    @Test func onboardingPicksReachSettingsAndSurviveReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "first-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux-next.json")
        try Data(#"{"terminal":{"fontSize":15},"appearance":{"themeFile":"test"}}"#.utf8).write(to: url)
        let themes = directory.appending(path: "themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try Data(#"{"density":{"basedOn":"compact","tokens":{"tabCornerRadius":2}}}"#.utf8)
            .write(to: themes.appending(path: "test.json"))
        let recommendations = FixedManagedPreferenceReader(ManagedPreferences(recommended: [
            "tabs.newTabTemplate": .string("terminal"),
            "appearance.background": .string("daily"),
        ]))
        let design = DesignSettings()
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []),
                                          design: design, fileURL: url,
                                          managedReader: recommendations, managedWatchFiles: [])
        await settings.reload()
        let source = FirstRunChoicesSettingsSource(settings: { settings })
        let model = OnboardingModel(services: MockOnboardingServices(), step: .makeItYours, choices: source)
        model.stepDidAppear()
        defer { model.makeItYours.stop() }
        #expect(model.makeItYours.choices == FirstRunChoices(workStyle: .terminal, density: .compact, background: "daily"))

        let onboarding = OnboardingPageProvider(model: model)
        _ = try await onboarding.call("cmux.onboarding.makeItYours.workStyle", params: ["value": "gui"], context: clicked(400))
        _ = try await onboarding.call("cmux.onboarding.makeItYours.density", params: ["value": "comfortable"], context: clicked(401))
        _ = try await onboarding.call("cmux.onboarding.makeItYours.density", params: ["value": "standard"], context: clicked(402))
        _ = try await onboarding.call("cmux.onboarding.makeItYours.background", params: ["id": .null], context: clicked(403))
        await model.makeItYours.waitForWrites()

        let page = SettingsPageProvider(settings: settings)
        let rows = try await page.call("cmux.settings.list", params: [:], context: PageCallContext(page: "cmux.settings"))
        let expected = ["tabs.newTabTemplate": "minimal", "appearance.density": "cozy", "appearance.background": "none"]
        for (key, value) in expected {
            let row = try #require(rows.arrayValue?.first(where: { $0["key"]?.stringValue == key }))
            #expect(row["value"]?.stringValue == value)
            #expect(try await settings.file.value(at: key.split(separator: ".").map(String.init)) == .string(value))
        }
        #expect(try await settings.file.value(at: ["terminal", "fontSize"]) == .number(15))
        await settings.reload()
        #expect(source.currentChoices() == .recommended)
        #expect(design.densityTokens.id == "cozy")
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
