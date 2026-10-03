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

    @Test func sixStepsWithAccountsFiveWithout() {
        #expect(OnboardingModel(services: MockOnboardingServices()).steps == [.role, .projects, .defaultBrowser, .importData, .theme])
        let services = MockOnboardingServices()
        services.accountsView = NSView()
        let model = OnboardingModel(services: services)
        #expect(model.steps == [.role, .projects, .defaultBrowser, .importData, .theme, .accounts])
        for _ in 0..<5 { model.next() }
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
        func report(_ index: Int, _ profile: BrowserSourceProfile, _ kind: ImportDataKind?, bookmarks: Int, history: Int = 0) -> ImportProgress {
            ImportProgress(profileIndex: index, profileCount: 2, profile: profile, kind: kind, fraction: 0, counts: ImportCounts(bookmarks: bookmarks, history: history))
        }
        // Progress counts are cumulative over the plan: Work brings 5 bookmarks, then Side starts at 5.
        services.reports = [report(0, work, .bookmarks, bookmarks: 0), report(0, work, nil, bookmarks: 5),
                            report(1, side, .bookmarks, bookmarks: 5), report(1, side, .history, bookmarks: 8, history: 2)]
        var workBatch = ImportBatch(source: ImportSourceRecord(browser: .chrome, profileDirectory: "Profile 1", displayName: "Work",
                                                               proposedProfileID: "w", targetProfileID: "w"))
        workBatch.history = (0..<7).map { ImportedHistoryEntry(url: URL(string: "https://a.test/\($0)")!, title: nil, visitCount: 1, lastVisit: .now) }
        services.summary = ImportSummary(batches: [workBatch], failures: [side.id: "locked"])
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        await settle { model.importer.phase == .ready }
        model.importer.toggle(skipped)
        model.next()
        model.next()
        #expect(model.step == .importData, "a second click right after Import does not leave the step")
        await settle { services.importGate != nil }
        #expect(model.importer.rowState(work) == .done(ImportCounts(bookmarks: 5)))
        #expect(model.importer.rowState(side) == .importing(.history, ImportCounts(bookmarks: 3, history: 2)), "Side's counts start from its first report")
        #expect(model.importer.rowState(skipped) == .idle)
        model.importer.redetect()
        #expect(model.importer.isImporting, "Check Again never cancels a running import")
        services.importGate?.resume()
        await settle { model.importer.summary != nil }
        #expect(model.importer.rowState(work) == .done(ImportCounts(history: 7)), "the summary's batch is what came over")
        #expect(model.importer.rowState(side) == .failed("locked"))
        #expect(model.importer.rowState(skipped) == .idle)
    }

    @Test func passwordsWaitForConsentAndReadNothingBefore() async throws {
        let services = MockOnboardingServices()
        services.passwordStore = true
        let work = profile("Profile 1", browser: .edge, kinds: [.bookmarks, .passwords])
        let home = profile("Default", browser: .chrome, kinds: [.bookmarks, .passwords])
        services.sources = [BrowserSource(browser: .chrome, appURL: nil, profiles: [home]), BrowserSource(browser: .edge, appURL: nil, profiles: [work])]
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        await settle { model.importer.phase == .ready }
        #expect(model.importer.kindChoices.last == .passwords)
        #expect(model.importer.kinds.contains(.passwords), "offered and checked like the rest")
        #expect(model.importer.plan.items.allSatisfy { !$0.kinds.contains(.passwords) }, "no passwords without consent")

        model.next()
        #expect(model.importer.isConfirmingPasswords)
        #expect(services.plans.isEmpty, "the consent screen comes before anything is read")
        #expect(model.importer.passwordProfiles == [work, home])
        #expect(model.importer.passwordKeychainItems == ["Microsoft Edge Safe Storage", "Chrome Safe Storage"])
        model.next()
        #expect(model.importer.isConfirmingPasswords, "a double click on Import does not also agree")

        model.importer.toggleConsent(home)
        model.importer.start()
        await settle { model.importer.summary != nil }
        let plan = try #require(services.plans.first)
        #expect(plan.items.map(\.kinds) == [[.bookmarks, .passwords], [.bookmarks]], "passwords only from the profile agreed to")
    }

    /// Import on the consent screen is the single confirmation: Touch ID (or
    /// the Mac's password) first; a cancel reads nothing and stays put.
    @Test func touchIDComesBeforeAnyPasswordIsRead() async {
        let services = MockOnboardingServices()
        services.passwordStore = true
        services.passwordAuthorization = false
        let work = profile("Profile 1", browser: .edge, kinds: [.bookmarks, .passwords])
        services.sources = [BrowserSource(browser: .edge, appURL: nil, profiles: [work])]
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        await settle { model.importer.phase == .ready }
        model.importer.start()
        #expect(services.authorizationReasons.isEmpty, "the list's Import only opens the consent screen")

        model.importer.start()
        await settle { model.importer.authorizationDenied }
        #expect(model.importer.isConfirmingPasswords && services.plans.isEmpty, "a cancelled confirmation reads nothing")
        #expect(services.authorizationReasons == [OnboardingStrings.passwordsAuthReason])

        services.passwordAuthorization = true
        model.importer.start()
        await settle { model.importer.summary != nil }
        #expect(!model.importer.authorizationDenied)
        #expect(services.plans.first?.items.map(\.kinds) == [[.bookmarks, .passwords]])
        #expect(services.authorizationReasons.count == 2, "one confirmation per import")
    }

    /// A Touch ID answer that comes after Back, Cancel or Import Without
    /// Passwords starts nothing, even once the consent screen is back.
    @Test func aLateTouchIDAnswerImportsNothing() async {
        let services = MockOnboardingServices()
        services.passwordStore = true
        services.holdsAuthorization = true
        let work = profile("Profile 1", browser: .edge, kinds: [.bookmarks, .passwords])
        services.sources = [BrowserSource(browser: .edge, appURL: nil, profiles: [work])]
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        await settle { model.importer.phase == .ready }
        model.importer.start()
        model.importer.start()
        await settle { services.authorizationReasons.count == 1 }
        #expect(model.importer.authorizing)

        model.importer.backFromConsent()
        #expect(!model.importer.authorizing)
        model.importer.start()
        #expect(model.importer.isConfirmingPasswords)
        services.answerAuthorizations()
        for _ in 0..<20 { await Task.yield() }
        #expect(model.importer.isConfirmingPasswords && services.plans.isEmpty, "the earlier sheet's answer is not this screen's Import")

        model.importer.start()
        await settle { services.authorizationReasons.count == 2 }
        model.importer.cancel()
        services.answerAuthorizations()
        for _ in 0..<20 { await Task.yield() }
        #expect(services.plans.isEmpty && !model.importer.authorizing)
    }

    /// Without passwords there is nothing to confirm.
    @Test func importWithoutPasswordsNeedsNoTouchID() async {
        let services = MockOnboardingServices()
        services.passwordStore = true
        services.passwordAuthorization = false
        let work = profile("Profile 1", browser: .edge, kinds: [.bookmarks, .passwords])
        services.sources = [BrowserSource(browser: .edge, appURL: nil, profiles: [work])]
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        await settle { model.importer.phase == .ready }
        model.importer.start()
        model.importer.skipPasswords()
        await settle { model.importer.summary != nil }
        #expect(services.authorizationReasons.isEmpty)
    }

    @Test func consentCanBeSkippedOrLeft() async {
        let services = MockOnboardingServices()
        services.passwordStore = true
        let work = profile("Profile 1", browser: .edge, kinds: [.bookmarks, .passwords])
        services.sources = [BrowserSource(browser: .edge, appURL: nil, profiles: [work])]
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        await settle { model.importer.phase == .ready }
        model.importer.start()
        model.importer.backFromConsent()
        #expect(model.importer.phase == .ready && services.plans.isEmpty)
        model.importer.start()
        model.importer.skipPasswords()
        await settle { model.importer.summary != nil }
        #expect(services.plans.map { $0.items.map(\.kinds) } == [[[.bookmarks]]])
    }

    @Test func noPasswordStoreNoPasswordChoice() async {
        let services = MockOnboardingServices()
        services.sources = [BrowserSource(browser: .edge, appURL: nil, profiles: [profile("Default", browser: .edge, kinds: [.bookmarks, .passwords])])]
        let model = OnboardingModel(services: services, start: .importData)
        model.stepDidAppear()
        await settle { model.importer.phase == .ready }
        #expect(!model.importer.kindChoices.contains(.passwords))
        model.next()
        #expect(!model.importer.isConfirmingPasswords)
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
        let model = OnboardingModel(services: MockOnboardingServices(defaultApps: registry), start: .defaultBrowser)
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
        let model = OnboardingModel(services: MockOnboardingServices(defaultApps: registry), start: .defaultBrowser)
        model.defaults.request(.webBrowser)
        await settle { model.defaults.pending.isEmpty }
        #expect(!model.defaults.isClaimed(.webBrowser))
        #expect(model.defaults.errors.isEmpty)
    }
}
