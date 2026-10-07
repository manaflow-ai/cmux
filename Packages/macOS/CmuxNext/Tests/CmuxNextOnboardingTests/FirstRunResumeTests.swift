import AppKit
import Foundation
import Testing
@testable import CmuxNextOnboarding

/// Only Skip or Done ends the first run. A closed or rebuilt window, a quit,
/// a crash or a new build leaves it unfinished, and it resumes at its step.
@MainActor
@Suite struct FirstRunResumeTests {
    static func stateFile() -> OnboardingStateFile {
        OnboardingStateFile(url: FileManager.default.temporaryDirectory
            .appending(path: "onboarding-\(UUID().uuidString)/onboarding.json"))
    }

    /// The unfinished run and its step are kept in the file: a new instance
    /// (a relaunch) reads them; Skip or Done then ends the run.
    @Test func anUnfinishedRunIsReadBackFromTheFile() throws {
        let written = Self.stateFile()
        defer { try? FileManager.default.removeItem(at: written.url.deletingLastPathComponent()) }
        try written.markProgress(.importData)
        let relaunched = OnboardingStateFile(url: written.url)
        #expect(relaunched.needsOnboarding())
        #expect(relaunched.resumeStep() == .importData)
        try relaunched.markDone(completed: false)
        let after = OnboardingStateFile(url: written.url)
        #expect(!after.needsOnboarding())
        #expect(after.resumeStep() == nil)
    }

    /// A relaunch opens the first run at the saved step, even a step that
    /// another group also has (classic sessions are in Import and Sync too).
    @Test func aRelaunchResumesTheFirstRunAtItsStep() {
        let services = MockOnboardingServices()
        // The mock leaves out each step the App does not supply; the App always has Accounts.
        services.accountsView = NSView()
        services.canImportClassicSessions = true
        let model = OnboardingModel(services: services, resumingFirstRunAt: .classicSessions)
        #expect(model.isFirstRun)
        #expect(model.step == .classicSessions)
        #expect(model.steps.contains(.accounts) && model.steps.contains(.importData))
    }

    /// The first run reports each step it shows, so the App can keep it.
    @Test func theFirstRunReportsItsSteps() {
        let services = MockOnboardingServices()
        let model = OnboardingModel(services: services)
        model.next()
        #expect(services.reached.first == model.steps.first)
        #expect(services.reached.last == model.step)
        // A group opened from elsewhere is not the first run and saves nothing.
        let other = MockOnboardingServices()
        let group = OnboardingModel(services: other, start: .projects)
        group.next()
        #expect(!group.isFirstRun && other.reached.isEmpty)
    }

    /// Closing the window (close button, or the App rebuilding it) does not
    /// end the run; Escape (Skip) does.
    @Test func closingTheWindowKeepsTheRunAndSkipEndsIt() {
        let services = MockOnboardingServices()
        let model = OnboardingModel(services: services)
        let controller = OnboardingWindowController(model: model)
        controller.window?.close()
        #expect(services.ended == nil, "a closed window is not a skip")
        let skipping = MockOnboardingServices()
        let skipped = OnboardingModel(services: skipping)
        skipped.finish(completed: false)
        #expect(skipping.ended == false)
    }
}
