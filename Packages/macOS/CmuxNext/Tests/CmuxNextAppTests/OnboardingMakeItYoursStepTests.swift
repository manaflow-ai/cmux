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

    /// Skip puts back what was set when the step opened, in one write; with nothing picked it writes nothing.
    @Test func skipPutsBackTheOpeningChoices() async {
        let opening = FirstRunChoices(workStyle: .terminal, density: "compact", background: "daily")
        let source = Source(opening)
        let step = MakeItYoursStepModel(source: source)
        step.start()
        await Self.until { step.loaded }
        step.revert()
        #expect(source.applied.isEmpty, "nothing picked, nothing written")
        step.setWorkStyle(.gui)
        step.setDensity("comfortable")
        #expect(step.setBackground("hokusai-great-wave"))
        step.revert()
        #expect(source.current == opening)
        #expect(step.choices == opening)
        #expect(source.applied.count == 4, "three picks and one write back")
        #expect(source.applied.last?.old == FirstRunChoices(workStyle: .gui, density: "comfortable", background: "hokusai-great-wave"))
    }

    @Test func showingAgainRefreshesPicksButKeepsTheFirstSkipBaseline() async {
        let opening = FirstRunChoices(workStyle: .gui, density: "cozy", background: nil)
        let source = Source(opening)
        let step = MakeItYoursStepModel(source: source)
        step.start()
        await Self.until { step.loaded }

        source.current = FirstRunChoices(workStyle: .terminal, density: "spacious", background: "daily")
        step.start()
        #expect(step.choices == source.current)
        step.revert()
        #expect(source.current == opening)
    }

    @Test func skippingTheStepPutsBackTheOpeningChoices() async {
        let opening = FirstRunChoices(workStyle: .terminal, density: "compact", background: nil)
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
        let source = FirstRunChoicesSettingsSource(settings: { settings }, windowOpacity: { 0.7 })
        let opened = source.currentChoices()
        #expect(opened == .recommended)
        #expect(source.shownOpacity() == 0.7)

        let picked = FirstRunChoices(workStyle: .terminal, density: "spacious", background: "hokusai-great-wave", opacity: 0.45, material: .glassClear)
        source.apply(picked, from: opened)
        #expect(source.pickedWorkStyle == .terminal)
        await source.settled()
        let read = source.currentChoices()
        #expect(read.workStyle == .terminal)
        #expect(read.density == "spacious", "density lands in the same write, and the reload applies its tokens")
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
        await source.settled()
        let back = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        for path in [["tabs", "newTabTemplate"], ["appearance", "background"], ["appearance", "backgroundOpacity"], ["appearance", "backgroundBlur"]] {
            #expect(back.value(at: path) == nil, "\(path.joined(separator: ".")) is removed")
        }
    }

    /// A settings file writer that counts its publishes (each `edit` call is one write the file
    /// watcher sees), over the test writer.
    nonisolated final class CountingWriter: SettingsFileWriter, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var publishes: Int { lock.withLock { count } }
        func edit(_ edits: [SettingsFileEdit], file: URL) async throws -> [Int] {
            lock.withLock { count += 1 }
            return try await TestSettingsWriter().edit(edits, file: file)
        }
    }

    /// A settings owner over a temporary cmux.json holding `text`, counting its publishes.
    private func countedSettings(_ text: String) async throws -> (SettingsController, CountingWriter, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-make-yours-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(text.utf8).write(to: url)
        let writer = CountingWriter()
        let settings = SettingsController(writer: writer, registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (settings, writer, url)
    }

    /// A person's own settings the walk replays over: a custom density, Plain Backgrounds on, a set
    /// opacity, an empty object the file keeps, and a key the step never touches.
    private static let ownSettings = JSONValue.object([
        "appearance": .object(["density": .string("compact"), "customDensity": .string("my-tight"), "backgroundOpacity": .number(0.9)]),
        "ui": .object(["reducedBackgrounds": .bool(true)]),
        "tabs": .object([:]),
        "terminal": .object(["fontSize": .number(13)]),
    ]).prettyText() + "\n"

    /// One click is one publish of the settings file: a pick's own key and every linked edit it
    /// carries (density ends the custom density; a see-through opacity turns Plain Backgrounds off)
    /// go together, so the window behind never shows half a pick.
    @Test func eachPickIsOnePublishWithItsLinkedEdits() async throws {
        let (settings, writer, url) = try await countedSettings(Self.ownSettings)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = FirstRunChoicesSettingsSource(settings: { settings })
        let model = OnboardingModel(services: MockOnboardingServices(), step: .makeItYours, choices: source)
        let provider = OnboardingPageProvider(model: model)
        model.stepDidAppear()
        await Self.until { model.makeItYours.loaded }
        await source.settled()
        #expect(writer.publishes == 0, "opening the step reads, it writes nothing")

        _ = try await provider.call("cmux.onboarding.makeItYours.density", params: ["value": "spacious"], context: clicked(600))
        await source.settled()
        #expect(writer.publishes == 1)
        var file = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        #expect(file.value(at: ["appearance", "density"])?.stringValue == "spacious")
        #expect(file.value(at: ["appearance", "customDensity"]) == nil, "the built-in ends the custom density in the same write")
        #expect(settings.snapshot.density == "spacious")

        _ = try await provider.call("cmux.onboarding.makeItYours.opacity", params: ["value": 0.4], context: clicked(601))
        await source.settled()
        #expect(writer.publishes == 2)
        file = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        #expect(file.value(at: ["appearance", "backgroundOpacity"])?.doubleValue == 0.4)
        #expect(file.value(at: ["ui", "reducedBackgrounds"]) == nil, "a see-through opacity turns Plain Backgrounds off in the same write")

        for (index, (op, params)) in ([("workStyle", ["value": "terminal"]), ("background", ["id": "daily"]), ("material", ["value": "glass"])]
                                      as [(String, JSONValue)]).enumerated() {
            _ = try await provider.call("cmux.onboarding.makeItYours.\(op)", params: params, context: clicked(602 + Double(index)))
            await source.settled()
            #expect(writer.publishes == 3 + index, "\(op) is one publish")
        }

        // A change of several choices at once (a bundle) is still one publish.
        source.apply(FirstRunChoices(workStyle: .gui, density: "cozy", background: nil, opacity: 0.7, material: .frosted), from: model.makeItYours.choices)
        await source.settled()
        #expect(writer.publishes == 6)
    }

    /// The intro walk's screens (a look bundle, the trust and noise rows, Tidy) write their settings in
    /// one publish per click, refuse a path the walk does not own, and Skip puts them back with the picks.
    @Test func walkWritesAreOnePublishAndSkipPutsThemBack() async throws {
        let (settings, writer, url) = try await countedSettings(Self.ownSettings)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = FirstRunChoicesSettingsSource(settings: { settings })
        let model = OnboardingModel(services: MockOnboardingServices(), step: .makeItYours, choices: source)
        let provider = OnboardingPageProvider(model: model)
        model.stepDidAppear()
        await Self.until { model.makeItYours.loaded }
        await source.settled()

        let bundle: JSONValue = ["writes": .array([
            ["path": "appearance.twoTone", "value": "auto"],
            ["path": "ui.calm", "value": "calm"],
            ["path": "appearance.density", "value": "ultraCompact"],
            ["path": "agents.defaultPermissionMode", "value": "ask"],
            ["path": "notifications.sound", "value": .null],
        ])]
        _ = try await provider.call("cmux.onboarding.makeItYours.walk", params: bundle, context: clicked(650))
        await source.settled()
        #expect(writer.publishes == 1, "a bundle is one publish")
        let file = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
        #expect(file.value(at: ["appearance", "twoTone"])?.stringValue == "auto")
        #expect(file.value(at: ["ui", "calm"])?.stringValue == "calm")
        #expect(file.value(at: ["agents", "defaultPermissionMode"])?.stringValue == "ask")
        #expect(file.value(at: ["appearance", "customDensity"]) == nil, "a bundle's density carries its linked edit")
        await Self.until { model.makeItYours.choices.density == "ultraCompact" }
        #expect(model.makeItYours.walk["appearance.twoTone"]?.stringValue == "auto")

        await #expect(throws: (any Error).self) {
            _ = try await provider.call("cmux.onboarding.makeItYours.walk",
                                        params: ["writes": .array([["path": "terminal.fontSize", "value": 20]])], context: clicked(651))
        }
        await source.settled()
        #expect(writer.publishes == 1, "a path the walk does not own writes nothing")

        _ = try await provider.call("cmux.onboarding.skip", params: [:], context: clicked(652))
        await source.settled()
        #expect(writer.publishes == 2, "Skip is one publish")
        #expect(try String(contentsOf: url, encoding: .utf8) == Self.ownSettings)
    }

    /// A reopen from the palette right after Skip (its restore still queued behind a pick's write)
    /// reads its snapshot after that restore lands, so the first Skip is not lost.
    @Test func reopenRightAfterSkipKeepsTheSkip() async throws {
        let (settings, _, url) = try await countedSettings(Self.ownSettings)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = FirstRunChoicesSettingsSource(settings: { settings })
        source.markOpened()
        await source.settled()
        let opened = source.currentChoices()
        source.apply(FirstRunChoices(workStyle: opened.workStyle, density: "spacious", background: opened.background,
                                     opacity: 0.4, material: opened.material), from: opened)
        #expect(source.restoreOpened())
        source.markOpened()
        await source.settled()
        #expect(try JSONC.parse(String(contentsOf: url, encoding: .utf8)) == JSONC.parse(Self.ownSettings))
        #expect(source.restoreOpened(), "the reopened step has its own snapshot")
    }

    /// Skip and Escape put back the file as it was when the step opened, in one publish: every
    /// value a pick wrote, linked edits included, present or absent, so a walk replayed over a
    /// person's own settings loses nothing (the custom density and Plain Backgrounds come back).
    @Test func skipPutsTheFileBackAsItWasAtOpenInOnePublish() async throws {
        let (settings, writer, url) = try await countedSettings(Self.ownSettings)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = FirstRunChoicesSettingsSource(settings: { settings })
        let model = OnboardingModel(services: MockOnboardingServices(), step: .makeItYours, choices: source)
        let provider = OnboardingPageProvider(model: model)
        model.stepDidAppear()
        await Self.until { model.makeItYours.loaded }
        let opened = model.makeItYours.choices
        for (index, (op, params)) in ([("workStyle", ["value": "terminal"]), ("density", ["value": "spacious"]), ("background", ["id": "daily"]),
                                       ("opacity", ["value": 0.4]), ("material", ["value": "glass"])] as [(String, JSONValue)]).enumerated() {
            _ = try await provider.call("cmux.onboarding.makeItYours.\(op)", params: params, context: clicked(700 + Double(index)))
        }
        await source.settled()
        let beforeSkip = writer.publishes
        #expect(beforeSkip >= 1 && beforeSkip <= 5)
        var ended: Bool?
        model.onEnd = { ended = $0 }
        _ = try await provider.call("cmux.onboarding.skip", params: [:], context: clicked(710))
        await source.settled()
        #expect(ended == false)
        #expect(writer.publishes == beforeSkip + 1, "Skip is one publish")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(try JSONC.parse(text) == JSONC.parse(Self.ownSettings), "the file's values and keys are the ones at open")
        #expect(text == Self.ownSettings, "byte for byte, with this writer")
        #expect(model.makeItYours.choices == opened)
        #expect(source.pickedWorkStyle == opened.workStyle)
        #expect(settings.snapshot.density == "compact")

        // Skip with no pick writes nothing; a blank file stays blank (no emptied objects left behind).
        let (blank, blankWriter, blankURL) = try await countedSettings("{}")
        defer { try? FileManager.default.removeItem(at: blankURL.deletingLastPathComponent()) }
        let quiet = FirstRunChoicesSettingsSource(settings: { blank })
        let untouched = OnboardingModel(services: MockOnboardingServices(), step: .makeItYours, choices: quiet)
        untouched.stepDidAppear()
        await Self.until { untouched.makeItYours.loaded }
        untouched.skipStep()
        await quiet.settled()
        #expect(blankWriter.publishes == 0)

        let picked = FirstRunChoicesSettingsSource(settings: { blank })
        let walked = OnboardingModel(services: MockOnboardingServices(), step: .makeItYours, choices: picked)
        let page = OnboardingPageProvider(model: walked)
        walked.stepDidAppear()
        await Self.until { walked.makeItYours.loaded }
        _ = try await page.call("cmux.onboarding.makeItYours.workStyle", params: ["value": "terminal"], context: clicked(720))
        _ = try await page.call("cmux.onboarding.makeItYours.opacity", params: ["value": 0.3], context: clicked(721))
        await picked.settled()
        walked.skipStep()
        await picked.settled()
        #expect(try JSONC.parse(String(contentsOf: blankURL, encoding: .utf8)) == .object([:]))
    }

    /// The walk replayed (the palette's Make cmux Yours) opens on the person's current settings, not
    /// the defaults, and its Skip leaves everything as it was when it opened: the picks a first walk
    /// kept stay.
    @Test func aReplayedWalkOpensOnTheCurrentSettingsAndSkipKeepsThem() async throws {
        let (settings, writer, url) = try await countedSettings(Self.ownSettings)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = FirstRunChoicesSettingsSource(settings: { settings })
        let first = OnboardingModel(services: MockOnboardingServices(), step: .makeItYours, choices: source)
        let page = OnboardingPageProvider(model: first)
        first.stepDidAppear()
        await Self.until { first.makeItYours.loaded }
        _ = try await page.call("cmux.onboarding.makeItYours.workStyle", params: ["value": "terminal"], context: clicked(800))
        _ = try await page.call("cmux.onboarding.makeItYours.density", params: ["value": "spacious"], context: clicked(801))
        _ = try await page.call("cmux.onboarding.next", params: [:], context: clicked(802))
        await source.settled()
        #expect(first.ended)
        let kept = try String(contentsOf: url, encoding: .utf8)

        let replay = OnboardingModel(services: MockOnboardingServices(), step: .makeItYours, choices: source)
        let again = OnboardingPageProvider(model: replay)
        replay.stepDidAppear()
        await Self.until { replay.makeItYours.loaded }
        #expect(replay.makeItYours.choices.workStyle == .terminal, "the replay opens on what is set now")
        #expect(replay.makeItYours.choices.density == "spacious")
        _ = try await again.call("cmux.onboarding.makeItYours.background", params: ["id": "daily"], context: clicked(810))
        _ = try await again.call("cmux.onboarding.makeItYours.opacity", params: ["value": 0.3], context: clicked(811))
        await source.settled()
        let beforeSkip = writer.publishes
        _ = try await again.call("cmux.onboarding.skip", params: [:], context: clicked(812))
        await source.settled()
        #expect(writer.publishes == beforeSkip + 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == kept, "Skip puts back the replay's opening, not the defaults")
    }

    /// A write the settings refuse reaches the step, not only the log: the step records why and
    /// reads the settings again, so the page shows what the file holds.
    @Test func aRefusedWriteReadsTheSettingsAgain() async throws {
        let (settings, _, url) = try await countedSettings("{}")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let source = FirstRunChoicesSettingsSource(settings: { settings })
        let step = MakeItYoursStepModel(source: source)
        step.start()
        await Self.until { step.loaded }
        await source.settled()
        // The settings file is now a folder: the write fails.
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        step.setWorkStyle(.terminal)
        await source.settled()
        #expect(step.writeFailure != nil)
        #expect(step.choices.workStyle == .gui, "the page shows what the settings hold")
    }

    /// The offered backgrounds are built-in works this app has thumbnails for, Shuffle Paintings first.
    @Test func everyOfferedBackgroundIsABuiltInWorkWithAPreview() async {
        let source = FirstRunChoicesSettingsSource(settings: { nil })
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
