import CmuxNextBrowserImport
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextOnboarding

@MainActor
@Suite struct ModelTests {
    static let app = URL(fileURLWithPath: "/Applications/cmux.app")

    func profile(_ dir: String, kinds: [ImportDataKind] = [.bookmarks, .history]) -> BrowserSourceProfile {
        BrowserSourceProfile(browser: .chrome, directoryName: dir, displayName: dir, path: URL(fileURLWithPath: "/tmp/\(dir)"),
                             availability: Dictionary(uniqueKeysWithValues: kinds.map { ($0, DataAvailability.available) }))
    }

    /// Waits until `condition` holds, yielding to let model tasks run.
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    @Test func walksEveryStepAndFinishesCompleted() {
        let services = MockOnboardingServices()
        let model = OnboardingModel(services: services)
        #expect(model.isFirst)
        for _ in 0..<4 { model.next() }
        #expect(model.step == .tour && model.isLast)
        model.back()
        #expect(model.step == .defaultTerminal && !model.movedForward)
        model.skipStep()
        model.next()
        #expect(services.ended == true)
        #expect(model.ended)
    }

    @Test func themeAppliesLiveAndSkipRevertsIt() async {
        let services = MockOnboardingServices()
        services.selectedThemeName = "Nord"
        services.themeChoices = [ThemeChoice(name: "Nord", input: .ghosttyDefault), ThemeChoice(name: "Vesper", input: .ghosttyDefault)]
        let model = OnboardingModel(services: services)
        model.stepDidAppear()
        await settle { model.theme.choices.count == 3 }
        #expect(model.theme.choices.map(\.name) == [nil, "Nord", "Vesper"])
        model.theme.select("Vesper")
        model.theme.setDensity(.comfortable)
        #expect(services.selectedThemeName == "Vesper" && services.density == .comfortable)
        model.skipStep()
        #expect(services.selectedThemeName == "Nord" && services.density == .compact)
        #expect(model.step == .importData)
    }

    @Test func continueKeepsTheThemeAndClosingRevertsIt() {
        let services = MockOnboardingServices()
        let model = OnboardingModel(services: services)
        model.theme.select("Vesper")
        model.next()
        model.finish(completed: true)
        #expect(services.selectedThemeName == "Vesper")

        let other = MockOnboardingServices()
        let closing = OnboardingModel(services: other)
        closing.theme.select("Vesper")
        closing.finish(completed: false)
        #expect(other.selectedThemeName == nil)
        #expect(other.ended == false)
    }

    @Test func closingAfterContinuingPastTheThemeKeepsIt() {
        let services = MockOnboardingServices()
        let model = OnboardingModel(services: services)
        model.theme.select("Vesper")
        model.next()
        model.next()
        model.finish(completed: false)
        #expect(services.selectedThemeName == "Vesper")
        #expect(services.ended == false)
    }

    @Test func importDetectsSelectsAndRuns() async {
        let services = MockOnboardingServices()
        let work = profile("Profile 1")
        let empty = profile("Profile 2", kinds: [])
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [empty, work])]
        var batch = ImportBatch(source: ImportSourceRecord(browser: .chrome, profileDirectory: "Profile 1", displayName: "Work",
                                                            proposedProfileID: "p", targetProfileID: "default"))
        batch.openTabs = [ImportedTab(url: URL(string: "https://a.example.com")!, title: "A")]
        batch.extensions = [ImportedExtension(id: String(repeating: "a", count: 32), name: "Ext")]
        services.summary = ImportSummary(batches: [batch])
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        await settle { model.importer.phase == .ready }
        #expect(model.importer.selectedProfiles == [work.id], "the first importable profile is preselected")
        model.importer.toggle(empty)
        #expect(model.importer.selectedProfiles == [work.id], "a profile with nothing to import cannot be selected")
        model.importer.toggle(.openTabs)
        #expect(model.importer.plan.items.first?.kinds == [.bookmarks, .history])
        model.importer.start()
        await settle { if case .finished = model.importer.phase { true } else { false } }
        #expect(services.plans.count == 1)
        model.importer.openImportedTabs()
        model.importer.openImportedTabs()
        #expect(services.openedTabs.count == 1)
        model.importer.install(batch.extensions[0])
        #expect(services.installed == [batch.extensions[0].id])
    }

    @Test func importCanBeCancelled() async {
        let services = MockOnboardingServices()
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [profile("Default")])]
        services.holdsImport = true
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        await settle { model.importer.phase == .ready }
        model.importer.start()
        await settle { services.importGate != nil }
        #expect(model.importer.isImporting)
        model.importer.cancel()
        #expect(model.importer.phase == .cancelled)
        services.importGate?.resume()
        await settle { false }
        #expect(model.importer.phase == .cancelled)
        #expect(model.importer.canStart)
    }

    @Test func defaultBrowserAndTerminalClaimsUseTheRegistry() async {
        let registry = RecordingDefaultApps(appBundleURL: Self.app, schemes: ["https": URL(fileURLWithPath: "/Applications/Safari.app")])
        let services = MockOnboardingServices(defaultApps: registry)
        let model = OnboardingModel(services: services, start: .defaultBrowser)
        model.stepDidAppear()
        #expect(model.defaults.currentBrowserName == "Safari")
        #expect(!model.defaults.isClaimed(.webBrowser))
        model.defaults.request(.webBrowser)
        await settle { model.defaults.pending.isEmpty }
        #expect(model.defaults.isClaimed(.webBrowser))
        #expect(registry.log == ["scheme:http", "scheme:https"])
        model.defaults.requestAllTerminalClaims()
        await settle { model.defaults.pending.isEmpty }
        #expect(DefaultHandlerClaim.terminalClaims.allSatisfy(model.defaults.isClaimed))
        #expect(registry.log.contains("type:public.zsh-script"))
    }

    @Test func refusedBrowserPromptLeavesItUnclaimedWithoutAnError() async {
        let registry = RecordingDefaultApps(appBundleURL: Self.app)
        registry.refusedSchemes = ["http"]
        let model = OnboardingModel(services: MockOnboardingServices(defaultApps: registry), start: .defaultBrowser)
        model.defaults.request(.webBrowser)
        await settle { model.defaults.pending.isEmpty }
        #expect(!model.defaults.isClaimed(.webBrowser))
        #expect(model.defaults.errors.isEmpty)
    }

    @Test func tourShowsLiveShortcuts() {
        let model = OnboardingModel(services: MockOnboardingServices(), start: .tour)
        #expect(model.tour.shortcuts(for: TourStepModel.pages[0]) == ["⇧⌘P"])
        model.tour.show(99)
        #expect(model.tour.current.kind == .screens)
    }
}
