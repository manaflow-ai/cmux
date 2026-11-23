import CmuxNextActions
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextPages
@testable import CmuxNextSettings
@testable import CmuxNextOnboarding
import CmuxTheme
import Foundation
import Testing

/// Make cmux Yours (cmux#48416, cmux#49636), the first run's one setup screen: it reads the person's
/// settings, writes only what they change (each pick at once, as a change from what was set), offers
/// what Settings > Appearance has (every density, Text Size, a theme, every accent and window style, a
/// background with Opacity and Material), refuses what it does not offer, takes its picks only from the
/// page's own ops on its own step, and Skip puts back what was set when it opened. It shows once, and a
/// dev build shows it only when armed for one launch.
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
        func themes() -> [FirstRunTheme] {
            [FirstRunTheme(id: "light:Nord Light,dark:Nord", name: "Nord", light: ["#E5E9F0"], dark: ["#2E3440"]),
             FirstRunTheme(id: "Dracula", name: "Dracula", light: ["#282A36"], dark: ["#282A36"])]
        }
        func textSize(density: String) -> Double? { density == "spacious" ? 16 : 14 }
        func accentSwatch(_ accent: String) -> String? { accent == "art" ? nil : accent == "red" ? "#E06C75" : "#888888" }
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

    /// cmux#49636: the look rows Settings > Appearance has: Text Size, Theme, Accent and Window Style.
    @Test func theLookRowsWriteSettingsKeysAndRefuseWhatIsNotOffered() async {
        let source = Source()
        let step = MakeItYoursStepModel(source: source)
        step.start()
        await Self.until { step.loaded }
        #expect(step.shownTextSize == 14, "unset, Text Size is the density's")
        #expect(step.setDensity("spacious"))
        #expect(step.shownTextSize == 16, "and follows the density picked")
        #expect(step.setTextSize(16.6))
        #expect(source.current.textSize == 17, "whole points, Settings' step")
        #expect(!step.setTextSize(9) && !step.setTextSize(21) && !step.setTextSize(.infinity))
        #expect(step.setTextSize(nil))
        #expect(source.current.textSize == nil, "nil puts back the density's")
        #expect(step.setTheme("light:Nord Light,dark:Nord"))
        #expect(source.current.theme == "light:Nord Light,dark:Nord")
        #expect(!step.setTheme("Not A Theme"))
        #expect(step.setTheme(nil))
        #expect(source.current.theme == nil)
        for accent in FirstRunChoices.accents {
            #expect(step.setAccent(accent))
            #expect(source.current.accent == accent)
        }
        #expect(!step.setAccent("chartreuse"))
        for style in FirstRunChoices.windowStyles {
            #expect(step.setWindowStyle(style))
            #expect(source.current.windowStyle == style)
        }
        #expect(!step.setWindowStyle("skeuomorphic"))
    }

    /// The step offers every accent and window style Settings has, by the same values.
    @Test func everyAccentAndWindowStyleSettingsHasIsOffered() {
        #expect(FirstRunChoices.accents == ThemeAccent.allCases.map(\.rawValue) + [AccentSetting.artID])
        #expect(FirstRunChoices.windowStyles == ChromeStyle.allCases.map(\.rawValue))
        #expect(FirstRunChoices.defaultAccent == AccentSetting.fallback.rawValue)
        #expect(FirstRunChoices.defaultWindowStyle == ChromeStyleSetting.fallback.rawValue)
        #expect(FirstRunChoices.textSizes == InterfaceSizeSetting.range)
        let themes = FirstRunChoicesSettingsSource.offeredThemes
        #expect(Set(themes.map(\.name)).count == themes.count)
        #expect(FirstRunChoicesSettingsSource.themeSpec(light: "Nord Light", dark: "Nord") == "light:Nord Light,dark:Nord")
        #expect(FirstRunChoicesSettingsSource.themeSpec(light: nil, dark: "Dracula") == "Dracula")
        let source = FirstRunChoicesSettingsSource(settings: { nil }, setDensity: { _ in }, themeSwatch: { $0 == "Nord" ? ["#2E3440"] : ["#ECEFF4"] })
        let nord = source.themes().first { $0.name == "Nord" }
        #expect(nord?.dark == ["#2E3440"] && nord?.light == ["#ECEFF4"], "each side's own swatch")
        #expect(source.textSize(density: "cozy") == Double(DensityPreset.cozy.tokens.bodySize))
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
        _ = try await provider.call("cmux.onboarding.makeItYours.textSize", params: ["value": 18], context: clicked(406))
        _ = try await provider.call("cmux.onboarding.makeItYours.theme", params: ["id": "Dracula"], context: clicked(407))
        _ = try await provider.call("cmux.onboarding.makeItYours.accent", params: ["value": "cyan"], context: clicked(408))
        _ = try await provider.call("cmux.onboarding.makeItYours.windowStyle", params: ["value": "floating"], context: clicked(409))
        var ended: Bool?
        model.onEnd = { ended = $0 }
        _ = try await provider.call("cmux.onboarding.skip", params: [:], context: clicked(410))
        #expect(skipped.current == opened)
        #expect(skipped.applied.last?.old == FirstRunChoices(workStyle: .terminal, density: "spacious", background: "daily", opacity: 0.4, material: .glass,
                                                             textSize: 18, theme: "Dracula", accent: "cyan", windowStyle: "floating"))
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
        #expect(make["textSize"]?.doubleValue == 14)
        #expect(make["textSizeSet"]?.boolValue == false)
        #expect(make["textSizeMin"]?.doubleValue == 10 && make["textSizeMax"]?.doubleValue == 20)
        #expect(make["theme"] == .null)
        #expect(make["themes"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["light:Nord Light,dark:Nord", "Dracula"])
        #expect(make["themes"]?.arrayValue?.first?["dark"]?.arrayValue?.compactMap(\.stringValue) == ["#2E3440"])
        #expect(make["accent"]?.stringValue == "neutral")
        #expect(make["accents"]?.arrayValue?.compactMap(\.stringValue) == FirstRunChoices.accents)
        #expect(make["accentSwatches"]?["red"]?.stringValue == "#E06C75")
        #expect(make["accentSwatches"]?["art"] == nil, "Art Color has no swatch of its own")
        #expect(make["windowStyle"]?.stringValue == "flat")
        #expect(make["windowStyles"]?.arrayValue?.compactMap(\.stringValue) == FirstRunChoices.windowStyles)
        #expect(state["footer"]?["primary"]?.stringValue == "continue")

        _ = try await provider.call("cmux.onboarding.makeItYours.workStyle", params: ["value": "terminal"], context: clicked(300))
        _ = try await provider.call("cmux.onboarding.makeItYours.density", params: ["value": "spacious"], context: clicked(301))
        _ = try await provider.call("cmux.onboarding.makeItYours.background", params: ["id": "daily"], context: clicked(302))
        _ = try await provider.call("cmux.onboarding.makeItYours.opacity", params: ["value": 0.55], context: clicked(303))
        _ = try await provider.call("cmux.onboarding.makeItYours.material", params: ["value": "frosted"], context: clicked(304))
        _ = try await provider.call("cmux.onboarding.makeItYours.textSize", params: ["value": 15], context: clicked(311))
        _ = try await provider.call("cmux.onboarding.makeItYours.theme", params: ["id": "light:Nord Light,dark:Nord"], context: clicked(312))
        _ = try await provider.call("cmux.onboarding.makeItYours.accent", params: ["value": "magenta"], context: clicked(313))
        _ = try await provider.call("cmux.onboarding.makeItYours.windowStyle", params: ["value": "card"], context: clicked(314))
        #expect(source.current == FirstRunChoices(workStyle: .terminal, density: "spacious", background: "daily", opacity: 0.55, material: .frosted,
                                                  textSize: 15, theme: "light:Nord Light,dark:Nord", accent: "magenta", windowStyle: "card"))
        let after = try await provider.call("cmux.onboarding.state", params: [:], context: PageCallContext(page: "cmux.onboarding"))
        #expect(after["makeItYours"]?["textSize"]?.doubleValue == 15)
        #expect(after["makeItYours"]?["textSizeSet"]?.boolValue == true)
        #expect(after["makeItYours"]?["theme"]?.stringValue == "light:Nord Light,dark:Nord")
        #expect(after["makeItYours"]?["accent"]?.stringValue == "magenta")
        #expect(after["makeItYours"]?["windowStyle"]?.stringValue == "card")
        #expect(after["makeItYours"]?["opacity"]?.doubleValue == 0.55)
        #expect(after["makeItYours"]?["opacitySet"]?.boolValue == true)
        #expect(after["makeItYours"]?["material"]?.stringValue == "frosted")
        for (op, params) in [("background", ["id": "elsewhere"]), ("density", ["value": "huge"]), ("material", ["value": "chrome"]),
                             ("opacity", ["value": 2]), ("textSize", ["value": 40]), ("textSize", ["value": "big"]), ("theme", ["id": "Solarized"]),
                             ("accent", ["value": "chartreuse"]), ("windowStyle", ["value": "skeuomorphic"])] as [(String, JSONValue)] {
            await #expect(throws: PageError.self) {
                _ = try await provider.call("cmux.onboarding.makeItYours.\(op)", params: params, context: clicked(310))
            }
        }
        _ = try await provider.call("cmux.onboarding.makeItYours.background", params: ["id": .null], context: clicked(305))
        #expect(source.current.background == nil, "null is no background")
        _ = try await provider.call("cmux.onboarding.makeItYours.textSize", params: ["value": .null], context: clicked(315))
        _ = try await provider.call("cmux.onboarding.makeItYours.theme", params: ["id": .null], context: clicked(316))
        #expect(source.current.textSize == nil && source.current.theme == nil, "null puts back the density's size and the config's theme")

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

        let picked = FirstRunChoices(workStyle: .terminal, density: "spacious", background: "hokusai-great-wave", opacity: 0.45, material: .glassClear,
                                     textSize: 15, theme: "light:Nord Light,dark:Nord", accent: "blue", windowStyle: "card-outlined")
        source.apply(picked, from: opened)
        #expect(densities.set == ["spacious"], "density goes through the density action, which saves and applies it")
        #expect(source.pickedWorkStyle == .terminal)
        // Window Style is written last (the opacity write before material may set a linked material of its own).
        await Self.until { settings.snapshot.root.value(at: ["appearance", "chromeStyle"])?.stringValue == "card-outlined" }
        let read = source.currentChoices()
        #expect(read.workStyle == .terminal)
        #expect(read.background == "hokusai-great-wave")
        #expect(read.opacity == 0.45)
        #expect(read.material == .glassClear)
        #expect(read.textSize == 15 && read.theme == "light:Nord Light,dark:Nord" && read.accent == "blue" && read.windowStyle == "card-outlined")
        let file = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        #expect(file.value(at: ["tabs", "newTabTemplate"])?.stringValue == "terminal")
        #expect(file.value(at: ["appearance", "background"])?.stringValue == "hokusai-great-wave")
        #expect(file.value(at: ["appearance", "backgroundOpacity"])?.doubleValue == 0.45)
        #expect(file.value(at: ["appearance", "backgroundBlur"])?.stringValue == "glass-clear")
        #expect(file.value(at: ["appearance", "metrics", "chromeFontSize"])?.doubleValue == 15)
        #expect(file.value(at: ["appearance", "theme"])?.stringValue == "light:Nord Light,dark:Nord")
        #expect(file.value(at: ["appearance", "accent"])?.stringValue == "blue")
        #expect(file.value(at: ["appearance", "chromeStyle"])?.stringValue == "card-outlined")

        // Skip's write back: every key the window set is removed again.
        source.apply(FirstRunChoices(workStyle: .gui, density: "spacious", background: nil), from: picked)
        await Self.until { settings.snapshot.root.value(at: ["appearance", "chromeStyle"]) == nil }
        let back = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        for path in [["tabs", "newTabTemplate"], ["appearance", "background"], ["appearance", "backgroundOpacity"], ["appearance", "backgroundBlur"],
                     ["appearance", "metrics", "chromeFontSize"], ["appearance", "theme"], ["appearance", "accent"], ["appearance", "chromeStyle"]] {
            #expect(back.value(at: path) == nil, "\(path.joined(separator: ".")) is removed")
        }
    }

    /// Skip over a real settings owner puts the person's own file back as it was: a pick's linked
    /// writes (a built-in density ends a custom one; a see-through Opacity turns Plain Backgrounds off)
    /// are undone too, and a key the file did not hold stays absent rather than pinned to what showed.
    @Test func skipPutsThePersonsOwnFileBackWithWhatPicksChangedBesideThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-make-yours-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        let original = #"{"appearance": {"density": "compact", "customDensity": "mine", "accent": "red"}, "ui": {"reducedBackgrounds": true}}"#
        try Data(original.utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        // The density action's own write: a built-in density removes the custom one.
        let source = FirstRunChoicesSettingsSource(settings: { settings }, setDensity: { preset in
            Task { try? await settings.setSetting(at: DensitySetting.configPath, to: .string(preset), by: .user) }
        })
        let step = MakeItYoursStepModel(source: source)
        step.start()
        await Self.until { step.loaded }
        #expect(step.setDensity("spacious"))
        #expect(step.setOpacity(0.5))
        #expect(step.setAccent("blue"))
        #expect(step.setWindowStyle("card"))
        await Self.until { settings.fileRoot.value(at: FirstRunChoicesSettingsSource.windowStylePath)?.stringValue == "card" }
        await Self.until { settings.fileRoot.value(at: DensitySetting.configPath)?.stringValue == "spacious" }
        #expect(settings.fileRoot.value(at: CustomDensitySelectionSetting.configPath) == nil, "the density pick ended the custom density")
        #expect(settings.fileRoot.value(at: ReducedBackgroundsSetting.configPath)?.boolValue != true, "the Opacity pick turned Plain Backgrounds off")

        step.revert()
        await Self.until { settings.fileRoot.value(at: FirstRunChoicesSettingsSource.windowStylePath) == nil }
        let back = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        let was = try JSONC.parse(original)
        for path in FirstRunChoicesSettingsSource.keptPaths {
            #expect(back.value(at: path) == was.value(at: path), "\(path.joined(separator: ".")) is what the file held")
        }
        #expect(step.choices == step.opened)
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

    /// cmux#49636: the step shows once, and never again once it showed, however it ended (Continue, Skip,
    /// Escape or the close button: the flag is set when it shows, not when it ends).
    @Test func theStepNeverShowsAgainAfterItShowedHoweverItEnded() async throws {
        let defaults = try #require(UserDefaults(testSuiteName: "cmux-make-yours-\(UUID().uuidString)"))
        var shown: [OnboardingWindowController] = []
        let presenter = OnboardingWindowPresenter(makeModel: { OnboardingModel(services: MockOnboardingServices(), step: $0, choices: Source()) },
                                                  activeLook: nil, present: { shown.append($0) })
        await presenter.showMakeItYoursAtFirstRun(isFirstRun: true, defaults: defaults)
        #expect(shown.count == 1)
        shown.last?.model.skipStep()
        shown.last?.close()
        await presenter.untilClosed()
        await presenter.showMakeItYoursAtFirstRun(isFirstRun: true, defaults: defaults)
        #expect(shown.count == 1, "a later first-run-looking launch does not show it again")
    }

    /// cmux#49636: a dev build (Debug) never shows the step at launch, first run or not, and marks nothing;
    /// the one-time preview pass shows it once (even past the once flag) and is used up; `--onboarding`
    /// (the first run asked for) still shows it.
    @Test func aDevBuildShowsTheStepOnlyWhenArmedForOneLaunch() async throws {
        var shown: [OnboardingModel.Step] = []
        let presenter = OnboardingWindowPresenter(makeModel: { OnboardingModel(services: MockOnboardingServices(), step: $0, choices: Source()) },
                                                  activeLook: nil, present: { shown.append($0.model.step) })
        let dev = try #require(UserDefaults(testSuiteName: "cmux-make-yours-\(UUID().uuidString)"))
        await presenter.showMakeItYoursAtFirstRun(isFirstRun: true, devBuild: true, defaults: dev)
        #expect(shown.isEmpty, "a dev build's first run shows nothing")
        #expect(!dev.bool(forKey: OnboardingWindowPresenter.makeItYoursShownKey))

        dev.set(true, forKey: OnboardingWindowPresenter.makeItYoursShownKey)
        dev.set(true, forKey: OnboardingWindowPresenter.makeItYoursPreviewKey)
        await presenter.showMakeItYoursAtFirstRun(isFirstRun: false, devBuild: true, defaults: dev)
        #expect(shown == [.makeItYours], "armed: it shows once, past the once flag, first run or not")
        #expect(!dev.bool(forKey: OnboardingWindowPresenter.makeItYoursPreviewKey), "the pass is used up")
        presenter.controller?.close()
        await presenter.untilClosed()
        await presenter.showMakeItYoursAtFirstRun(isFirstRun: true, devBuild: true, defaults: dev)
        #expect(shown == [.makeItYours], "the next launch shows nothing")

        let asked = try #require(UserDefaults(testSuiteName: "cmux-make-yours-\(UUID().uuidString)"))
        let firstRun = OnboardingWindowPresenter(makeModel: { OnboardingModel(services: MockOnboardingServices(), step: $0, choices: Source()) },
                                                 activeLook: nil, present: { shown.append($0.model.step); $0.close() })
        _ = await firstRun.showLaunchSteps(.firstRun, isFirstRun: true, devBuild: true, defaults: asked)
        #expect(shown == [.makeItYours, .makeItYours], "--onboarding asks for the first run, in a dev build too")
        let plain = OnboardingWindowPresenter(makeModel: { OnboardingModel(services: MockOnboardingServices(), step: $0, choices: Source()) },
                                              activeLook: nil, present: { shown.append($0.model.step); $0.close() })
        let devDefault = try #require(UserDefaults(testSuiteName: "cmux-make-yours-\(UUID().uuidString)"))
        _ = await plain.showLaunchSteps(.standard, isFirstRun: true, devBuild: true, defaults: devDefault)
        #expect(shown == [.makeItYours, .makeItYours], "a dev build's default launch leaves it out")
    }
}
