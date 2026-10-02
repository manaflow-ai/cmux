import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextOnboarding

@MainActor
@Suite struct ModelTests {
    static let app = URL(fileURLWithPath: "/Applications/cmux.app")

    func profile(_ dir: String, browser: ImportBrowser = .chrome, kinds: [ImportDataKind] = [.bookmarks, .history]) -> BrowserSourceProfile {
        BrowserSourceProfile(browser: browser, directoryName: dir, displayName: dir, path: URL(fileURLWithPath: "/tmp/\(dir)"),
                             availability: Dictionary(uniqueKeysWithValues: kinds.map { ($0, DataAvailability.available) }))
    }

    /// Waits until `condition` holds, yielding to let model tasks run.
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    @Test func fourStepsWithAccountsThreeWithout() {
        #expect(OnboardingModel(services: MockOnboardingServices()).steps == [.defaultBrowser, .importData, .theme])
        let services = MockOnboardingServices()
        services.accountsView = NSView()
        let model = OnboardingModel(services: services)
        #expect(model.steps == [.defaultBrowser, .importData, .theme, .accounts])
        for _ in 0..<3 { model.next() }
        #expect(model.step == .accounts && model.isLast)
        model.back()
        #expect(model.step == .theme)
        model.next()
        model.next()
        #expect(services.ended == true && model.ended)
    }

    @Test func themeAppliesLiveAndSkipRevertsIt() async {
        let services = MockOnboardingServices()
        services.selectedThemeName = "Nord"
        services.themeChoices = [ThemeChoice(name: "Nord", input: .ghosttyDefault), ThemeChoice(name: "Vesper", input: .ghosttyDefault)]
        let model = OnboardingModel(services: services, start: .theme)
        model.stepDidAppear()
        await settle { model.theme.choices.count == 3 }
        #expect(model.theme.choices.map(\.name) == [nil, "Nord", "Vesper"])
        model.theme.select("Vesper")
        #expect(services.selectedThemeName == "Vesper")
        model.skipStep()
        #expect(services.selectedThemeName == "Nord")
    }

    @Test func withoutAThemeOfTheirOwnTheDefaultIsAppleSystem() {
        let services = MockOnboardingServices()
        services.ghosttyHasOwnTheme = false
        services.selectedThemeName = "Nord"
        let model = OnboardingModel(services: services, start: .theme)
        #expect(OnboardingStrings.themeName(model.theme.choices[0]) == "Apple System (follows appearance)")
        model.theme.select(nil)
        #expect(services.selectedThemeName == nil, "choosing the default writes no theme")
        #expect(OnboardingStrings.themeName(OnboardingModel(services: MockOnboardingServices(), start: .theme).theme.choices[0]) == "Your Ghostty Theme")
    }

    @Test func continueKeepsTheThemeClosingBeforeRevertsIt() {
        let services = MockOnboardingServices()
        let model = OnboardingModel(services: services, start: .theme)
        model.theme.select("Vesper")
        model.next()
        #expect(services.selectedThemeName == "Vesper" && services.ended == true)

        let other = MockOnboardingServices()
        let closing = OnboardingModel(services: other, start: .theme)
        closing.theme.select("Vesper")
        closing.finish(completed: false)
        #expect(other.selectedThemeName == nil && other.ended == false)
    }

    @Test func importChecksEverythingAndImportRunsInPlace() async {
        let services = MockOnboardingServices()
        let work = profile("Profile 1")
        let empty = profile("Profile 2", kinds: [.extensions])
        let firefox = profile("Profiles/x", browser: .firefox, kinds: [.cookies])
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [empty, work]),
                            BrowserSource(browser: .firefox, appURL: nil, profiles: [firefox])]
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        await settle { model.importer.phase == .ready }
        #expect(model.importer.profiles == [work, firefox], "a profile with none of bookmarks, history, sign-ins is not listed")
        #expect(model.importer.selectedProfiles == [work.id, firefox.id])
        model.importer.toggle(firefox)
        model.importer.toggle(.history)
        #expect(model.importer.plan.items.map(\.kinds) == [[.bookmarks]])
        #expect(model.primaryTitle == OnboardingStrings.importButton)
        model.next()
        await settle { if case .finished = model.importer.phase { true } else { false } }
        #expect(services.plans.count == 1)
        #expect(model.step == .importData, "Import stays on the step so its rows show the result")
        #expect(model.primaryTitle == OnboardingStrings.continueButton)
        model.next()
        #expect(model.step == .theme)
        #expect(services.plans.count == 1, "Continue after an import does not run it again")
    }

    @Test func nothingCheckedContinuesWithoutImporting() async {
        let services = MockOnboardingServices()
        let work = profile("Profile 1")
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [work])]
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        await settle { model.importer.phase == .ready }
        model.importer.toggle(work)
        #expect(model.primaryTitle == OnboardingStrings.continueButton)
        model.next()
        #expect(model.step == .theme && services.plans.isEmpty)
    }

    @Test func rowsShowEachProfilesProgressThenItsCounts() async {
        let services = MockOnboardingServices()
        let work = profile("Profile 1")
        let side = profile("Profile 2")
        let skipped = profile("Profile 3")
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [work, side, skipped])]
        services.holdsImport = true
        services.summary = ImportSummary(batches: [], failures: [side.id: "locked"])
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        await settle { model.importer.phase == .ready }
        model.importer.toggle(skipped)
        model.next()
        await settle { services.importGate != nil }
        // The mock's one report is the first profile starting on bookmarks: its base.
        #expect(model.importer.rowState(work) == .importing(.bookmarks, ImportCounts()))
        #expect(model.importer.rowState(side) == .waiting)
        #expect(model.importer.rowState(skipped) == .idle)
        services.importGate?.resume()
        await settle { model.importer.summary != nil }
        #expect(model.importer.rowState(work) == .done(ImportCounts()), "a row's first report is its base")
        #expect(model.importer.rowState(side) == .failed("locked"))
        #expect(model.importer.rowState(skipped) == .idle)
    }

    @Test func edgeLeadsTheList() async {
        let services = MockOnboardingServices()
        let chrome = profile("Default")
        let edge = profile("Default", browser: .edge)
        let edgeBeta = profile("Default", browser: .edgeBeta)
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [chrome]),
                            BrowserSource(browser: .edgeBeta, appURL: nil, profiles: [edgeBeta]),
                            BrowserSource(browser: .edge, appURL: nil, profiles: [edge])]
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        await settle { model.importer.phase == .ready }
        #expect(model.importer.profiles == [edge, edgeBeta, chrome], "Edge first (stable, then its channels), otherwise detection order")
    }

    @Test func leavingTheFlowLetsTheImportFinish() async {
        let services = MockOnboardingServices()
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [profile("Default")])]
        services.holdsImport = true
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        await settle { model.importer.phase == .ready }
        model.next()
        await settle { services.importGate != nil }
        model.finish(completed: false)
        #expect(model.importer.isImporting)
        services.importGate?.resume()
        await settle { if case .finished = model.importer.phase { true } else { false } }
        #expect({ if case .finished = model.importer.phase { true } else { false } }())
    }

    @Test func defaultBrowserClaimUsesTheRegistry() async {
        let registry = RecordingDefaultApps(appBundleURL: Self.app, schemes: ["https": URL(fileURLWithPath: "/Applications/Safari.app")])
        let model = OnboardingModel(services: MockOnboardingServices(defaultApps: registry))
        model.stepDidAppear()
        #expect(model.defaults.currentBrowserName == "Safari")
        model.defaults.request(.webBrowser)
        await settle { model.defaults.pending.isEmpty }
        #expect(model.defaults.isClaimed(.webBrowser))
        #expect(registry.log == ["scheme:http", "scheme:https"])
    }

    @Test func refusedBrowserPromptLeavesItUnclaimedWithoutAnError() async {
        let registry = RecordingDefaultApps(appBundleURL: Self.app)
        registry.refusedSchemes = ["http"]
        let model = OnboardingModel(services: MockOnboardingServices(defaultApps: registry))
        model.defaults.request(.webBrowser)
        await settle { model.defaults.pending.isEmpty }
        #expect(!model.defaults.isClaimed(.webBrowser))
        #expect(model.defaults.errors.isEmpty)
    }
}
