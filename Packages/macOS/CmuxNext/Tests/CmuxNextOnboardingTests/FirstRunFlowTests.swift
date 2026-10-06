import AppKit
import Foundation
import Testing
@testable import CmuxNextOnboarding

/// The first run is two screens that each change something: agent
/// sign-ins, then browser import. Every other screen opens from its own
/// entry point, with only the screens that belong with it.
@MainActor
@Suite struct FirstRunFlowTests {
    /// Every optional screen available, so nothing is left out for lack of support.
    func everything() -> MockOnboardingServices {
        let services = MockOnboardingServices()
        services.accountsView = NSView()
        services.firstTaskView = NSView()
        services.computerUseSource = MockComputerUsePermissionSource()
        return services
    }

    @Test func theFirstRunIsSignInsThenImport() async {
        let services = everything()
        let model = OnboardingModel(services: services)
        #expect(model.steps == [.accounts, .importData])
        #expect(model.step == .accounts)
        model.next()
        #expect(model.step == .importData && model.isLast)
        // Browser detection reads other apps' data, so a person starts it (LAUNCH-NO-TCC-PROMPTS).
        #expect(model.primaryTitle == OnboardingStrings.findBrowsers)
        model.next()
        for _ in 0..<200 where model.importer.phase != .ready { await Task.yield() }
        #expect(model.primaryTitle == OnboardingStrings.done)
        model.next()
        #expect(services.ended == true)
    }

    @Test func withoutTheAccountsViewTheFirstRunIsImportAlone() {
        #expect(OnboardingModel(services: MockOnboardingServices()).steps == [.importData])
    }

    @Test func skippingEveryScreenEndsTheRunAsCompleted() {
        let services = everything()
        let model = OnboardingModel(services: services)
        model.skipStep()
        model.skipStep()
        #expect(services.ended == true && services.plans.isEmpty)
    }

    /// New Tab's Import and Sync: projects, then the chats to resume in them.
    @Test func projectsOpenWithTheChatsThatResumeInThem() {
        let model = OnboardingModel(services: everything(), start: .projects)
        #expect(model.steps == [.projects, .chats])
        #expect(model.step == .projects)
    }

    @Test func classicSessionsOpenWithTheWorkScreens() {
        let services = everything()
        services.canImportClassicSessions = true
        let model = OnboardingModel(services: services, start: .classicSessions)
        #expect(model.steps == [.projects, .classicSessions, .chats])
        #expect(model.step == .classicSessions)
    }

    @Test func aScreenOutsideBothGroupsOpensAlone() {
        for step: OnboardingModel.Step in [.defaultBrowser, .theme, .firstTask, .computerUse] {
            let model = OnboardingModel(services: everything(), start: step)
            #expect(model.steps == [step], "\(step) opens by itself")
            #expect(model.primaryTitle == OnboardingStrings.done)
        }
    }

    @Test func importFromBrowserOpensTheImportScreenOfTheFirstRun() {
        let model = OnboardingModel(services: everything(), start: .importData)
        #expect(model.step == .importData && model.steps == [.accounts, .importData])
    }

    /// "2 of 4" only helps on a long run; two or three screens show none.
    @Test func noStepCounterOnThreeScreensOrFewer() {
        func counterShows(_ model: OnboardingModel) -> Bool {
            let counter = "\(model.index + 1) of \(model.steps.count)"
            let footer = OnboardingFooter(context: OnboardingStepContext(model: model))
            return footer.subviews.contains { ($0 as? NSTextField)?.stringValue == counter && !$0.isHidden }
        }
        #expect(!counterShows(OnboardingModel(services: everything())))
        let work = everything()
        work.canImportClassicSessions = true
        #expect(!counterShows(OnboardingModel(services: work, start: .projects)))
    }
}
