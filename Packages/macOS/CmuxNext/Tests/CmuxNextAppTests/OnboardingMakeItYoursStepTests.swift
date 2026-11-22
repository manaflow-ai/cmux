import CmuxNextActions
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
@testable import CmuxNextOnboarding
import Foundation
import Testing

/// Make cmux Yours (cmux#48416, cmux#49636), the first run's one setup screen: it reads the person's
/// settings, writes only what they change (each pick at once, as a change from what was set), offers
/// every density Settings has, a background with Settings' Opacity and Material, refuses what it does
/// not offer, takes its picks only from the page's own ops on its own step, and Skip puts back what
/// was set when it opened.
@MainActor @Suite(.serialized) struct OnboardingMakeItYoursStepTests {
    @MainActor final class Source: FirstRunChoicesSource {
        var current: FirstRunChoices
        var applied: [(new: FirstRunChoices, old: FirstRunChoices)] = []
        var shown: Double? = 0.8

        init(_ current: FirstRunChoices = .recommended) { self.current = current }

        func currentChoices() -> FirstRunChoices { current }
        func densities() -> [FirstRunDensity] { FirstRunChoicesSettingsSource.densities }
        func backgrounds() async -> [FirstRunBackground] {
            [FirstRunBackground(id: "daily", name: ""), FirstRunBackground(id: "hokusai-great-wave", name: "The Great Wave")]
        }
        func shownOpacity() -> Double? { shown }
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
        let source = Source(FirstRunChoices(workStyle: .terminal, density: "compact", background: "daily", opacity: 0.5, material: .frosted))
        let step = MakeItYoursStepModel(source: source)
        step.start()
        await Self.until { step.loaded }
        #expect(step.choices == source.current)
        #expect(step.backgrounds.map(\.id) == ["daily", "hokusai-great-wave"])
        #expect(step.shownOpacity == 0.5, "a set Opacity is what the slider shows")
        #expect(source.applied.isEmpty)
    }

    /// cmux#49636: the step offered three of the five densities. It offers every one Settings has, in
    /// Settings' order and by Settings' names, and Default is the recommended answer.
    @Test func everyDensitySettingsHasIsOfferedByItsSettingsName() {
        let offered = FirstRunChoicesSettingsSource.densities
        #expect(offered.map(\.id) == DensityPreset.allCases.map(\.rawValue))
        #expect(offered.map(\.name) == ["Ultra-compact", "Compact", "Default", "Comfortable", "Spacious"])
        #expect(FirstRunChoices.recommended.density == DensityPreset.cozy.rawValue)
        #expect(FirstRunChoicesSettingsSource.density(nil) == "cozy")
        #expect(FirstRunChoicesSettingsSource.density("spacious") == "spacious", "an extreme reads as itself, not its neighbor")
        #expect(FirstRunChoicesSettingsSource.density("ultraCompact") == "ultraCompact")
    }

    @Test func eachPickWritesOnlyItsChangeAndWhatIsNotOfferedIsRefused() async {
        let source = Source()
        let step = MakeItYoursStepModel(source: source)
        step.start()
        await Self.until { step.loaded }
        #expect(step.shownOpacity == 0.8, "unset, the slider rests where the window is")
        #expect(step.setDensity("cozy"))
        #expect(source.applied.isEmpty, "the answer already set writes nothing")
        step.setWorkStyle(.terminal)
        #expect(source.applied.last?.old.workStyle == .gui)
        #expect(source.applied.last?.new.workStyle == .terminal)
        for density in DensityPreset.allCases.map(\.rawValue) {
            #expect(step.setDensity(density))
            #expect(source.current.density == density)
        }
        #expect(!step.setDensity("huge"))
        #expect(step.setBackground("hokusai-great-wave"))
        #expect(!step.setBackground("not-offered"))
        #expect(step.choices.background == "hokusai-great-wave", "a refused id changes nothing")
        #expect(step.setOpacity(0.35))
        #expect(!step.setOpacity(1.5) && !step.setOpacity(.nan))
        #expect(source.current.opacity == 0.35)
        step.setMaterial(.glassClear)
        #expect(source.current.material == .glassClear)
        #expect(step.setBackground(nil))
        #expect(source.applied.map(\.new.background).compactMap { $0 }.last == "hokusai-great-wave")
        #expect(source.current.background == nil)
    }

    /// Skip (and Escape) keeps the person's settings: every pick the window made live is put back in
    /// one write from what it shows now; Continue keeps them.
    @Test func skipPutsBackWhatWasSetAndContinueKeepsThePicks() async throws {
        let opened = FirstRunChoices(workStyle: .gui, density: "comfortable", background: nil)
        let skipped = Source(opened)
        let model = OnboardingModel(services: MockOnboardingServices(), step: .makeItYours, choices: skipped)
        let provider = OnboardingPageProvider(model: model)
        model.stepDidAppear()
        await Self.until { model.makeItYours.loaded }
        _ = try await provider.call("cmux.onboarding.makeItYours.workStyle", params: ["value": "terminal"], context: clicked(400))
        _ = try await provider.call("cmux.onboarding.makeItYours.density", params: ["value": "spacious"], context: clicked(401))
        _ = try await provider.call("cmux.onboarding.makeItYours.background", params: ["id": "daily"], context: clicked(402))
        _ = try await provider.call("cmux.onboarding.makeItYours.opacity", params: ["value": 0.4], context: clicked(403))
        _ = try await provider.call("cmux.onboarding.makeItYours.material", params: ["value": "glass"], context: clicked(404))
        var ended: Bool?
        model.onEnd = { ended = $0 }
        _ = try await provider.call("cmux.onboarding.skip", params: [:], context: clicked(405))
        #expect(skipped.current == opened)
        #expect(skipped.applied.last?.old == FirstRunChoices(workStyle: .terminal, density: "spacious", background: "daily", opacity: 0.4, material: .glass))
        #expect(ended == false)

        let continued = Source(opened)
        let other = OnboardingModel(services: MockOnboardingServices(), step: .makeItYours, choices: continued)
        let page = OnboardingPageProvider(model: other)
        other.stepDidAppear()
        await Self.until { other.makeItYours.loaded }
        _ = try await page.call("cmux.onboarding.makeItYours.density", params: ["value": "ultraCompact"], context: clicked(500))
        _ = try await page.call("cmux.onboarding.next", params: [:], context: clicked(501))
        #expect(continued.current.density == "ultraCompact")
        #expect(other.ended)
    }

    @Test func thePagesOpsSetTheChoicesOnTheirStepOnly() async throws {
        let source = Source()
        let model = OnboardingModel(services: MockOnboardingServices(), step: .makeItYours, choices: source)
        let provider = OnboardingPageProvider(model: model)
        model.stepDidAppear()
        await Self.until { model.makeItYours.loaded }
        let state = try await provider.call("cmux.onboarding.state", params: [:], context: PageCallContext(page: "cmux.onboarding"))
        let make = try #require(state["makeItYours"])
        #expect(state["step"]?.stringValue == "makeItYours")
        #expect(make["workStyle"]?.stringValue == "gui")
        #expect(make["density"]?.stringValue == "cozy")
        #expect(make["densities"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == DensityPreset.allCases.map(\.rawValue))
        #expect(make["background"] == .null)
        #expect(make["opacity"]?.doubleValue == 0.8)
        #expect(make["opacitySet"]?.boolValue == false)
        #expect(make["material"] == .null)
        #expect(make["materials"]?.arrayValue?.compactMap(\.stringValue) == ["none", "frosted", "glass", "glass-clear"])
        #expect(state["footer"]?["primary"]?.stringValue == "continue")

        _ = try await provider.call("cmux.onboarding.makeItYours.workStyle", params: ["value": "terminal"], context: clicked(300))
        _ = try await provider.call("cmux.onboarding.makeItYours.density", params: ["value": "spacious"], context: clicked(301))
        _ = try await provider.call("cmux.onboarding.makeItYours.background", params: ["id": "daily"], context: clicked(302))
        _ = try await provider.call("cmux.onboarding.makeItYours.opacity", params: ["value": 0.55], context: clicked(303))
        _ = try await provider.call("cmux.onboarding.makeItYours.material", params: ["value": "frosted"], context: clicked(304))
        #expect(source.current == FirstRunChoices(workStyle: .terminal, density: "spacious", background: "daily", opacity: 0.55, material: .frosted))
        let after = try await provider.call("cmux.onboarding.state", params: [:], context: PageCallContext(page: "cmux.onboarding"))
        #expect(after["makeItYours"]?["opacity"]?.doubleValue == 0.55)
        #expect(after["makeItYours"]?["opacitySet"]?.boolValue == true)
        #expect(after["makeItYours"]?["material"]?.stringValue == "frosted")
        for (op, params) in [("background", ["id": "elsewhere"]), ("density", ["value": "huge"]), ("material", ["value": "chrome"]),
                             ("opacity", ["value": 2])] as [(String, JSONValue)] {
            await #expect(throws: PageError.self) {
                _ = try await provider.call("cmux.onboarding.makeItYours.\(op)", params: params, context: clicked(310))
            }
        }
        _ = try await provider.call("cmux.onboarding.makeItYours.background", params: ["id": .null], context: clicked(305))
        #expect(source.current.background == nil, "null is no background")

        let other = OnboardingPageProvider(model: OnboardingModel(services: MockOnboardingServices(), step: .agents, choices: Source()))
        await #expect(throws: PageError.self) {
            _ = try await other.call("cmux.onboarding.makeItYours.workStyle", params: ["value": "terminal"], context: clicked(306))
        }
    }

    /// The source over a real settings owner: each pick lands in the settings file, the next read
    /// returns it, and putting a choice back unset removes its key.
    @Test func picksPersistThroughTheSettingsAndReadBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-make-yours-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        final class Densities { var set: [String] = [] }
        let densities = Densities()
        let source = FirstRunChoicesSettingsSource(settings: { settings }, setDensity: { densities.set.append($0) }, windowOpacity: { 0.7 })
        let opened = source.currentChoices()
        #expect(opened == .recommended)
        #expect(source.shownOpacity() == 0.7)

        let picked = FirstRunChoices(workStyle: .terminal, density: "spacious", background: "hokusai-great-wave", opacity: 0.45, material: .glassClear)
        source.apply(picked, from: opened)
        #expect(densities.set == ["spacious"], "density goes through the density action, which saves and applies it")
        #expect(source.pickedWorkStyle == .terminal)
        // Material is written last; the opacity write before it may already set a linked material of its own.
        await Self.until { settings.snapshot.windowBackground.material?.rawValue == "glass-clear" }
        let read = source.currentChoices()
        #expect(read.workStyle == .terminal)
        #expect(read.background == "hokusai-great-wave")
        #expect(read.opacity == 0.45)
        #expect(read.material == .glassClear)
        let file = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        #expect(file.value(at: ["tabs", "newTabTemplate"])?.stringValue == "terminal")
        #expect(file.value(at: ["appearance", "background"])?.stringValue == "hokusai-great-wave")
        #expect(file.value(at: ["appearance", "backgroundOpacity"])?.doubleValue == 0.45)
        #expect(file.value(at: ["appearance", "backgroundBlur"])?.stringValue == "glass-clear")

        // Skip's write back: every key the window set is removed again.
        source.apply(FirstRunChoices(workStyle: .gui, density: "spacious", background: nil), from: picked)
        await Self.until { settings.snapshot.windowBackground.material == nil && settings.snapshot.windowBackground.opacity == nil }
        let back = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        for path in [["tabs", "newTabTemplate"], ["appearance", "background"], ["appearance", "backgroundOpacity"], ["appearance", "backgroundBlur"]] {
            #expect(back.value(at: path) == nil, "\(path.joined(separator: ".")) is removed")
        }
    }

    /// The offered backgrounds are built-in works this app has thumbnails for, Shuffle Paintings first.
    @Test func everyOfferedBackgroundIsABuiltInWorkWithAPreview() async {
        let source = FirstRunChoicesSettingsSource(settings: { nil }, setDensity: { _ in })
        let offered = await source.backgrounds()
        #expect(offered.map(\.id) == FirstRunChoicesSettingsSource.offered)
        #expect(offered.first?.id == "daily")
        #expect(offered.allSatisfy { $0.preview?.hasPrefix("data:image/png;base64,") == true })
        #expect(offered.dropFirst().allSatisfy { !$0.name.isEmpty })
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
}
