import AppKit
import Foundation
import Testing
@testable import CmuxNextOnboarding

/// The close button means "not now": the first run comes back at its step
/// on the next two launches, then stops by itself. A quit or crash mid-step
/// resumes regardless; Skip or Done end it at once.
@MainActor
@Suite struct FirstRunNotNowTests {
    static func stateFile() -> OnboardingStateFile {
        OnboardingStateFile(url: FileManager.default.temporaryDirectory
            .appending(path: "onboarding-\(UUID().uuidString)/onboarding.json"))
    }

    /// Each launch is a new instance reading the same file.
    static func launch(_ file: OnboardingStateFile) -> OnboardingStateFile.LaunchShow {
        OnboardingStateFile(url: file.url).takeLaunchShow()
    }

    @Test func closeShowsTheRunAtTheNextTwoLaunchesOnly() throws {
        let file = Self.stateFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        #expect(Self.launch(file) == .start, "never seen")
        try file.markProgress(.chats, interacted: true)
        try file.markNotNow()
        #expect(Self.launch(file) == .resume(.chats))
        // The resumed window only shows its step; the person does not move.
        try file.markProgress(.chats, interacted: false)
        #expect(Self.launch(file) == .resume(.chats))
        try file.markProgress(.chats, interacted: false)
        #expect(Self.launch(file) == OnboardingStateFile.LaunchShow.none)
        #expect(Self.launch(file) == OnboardingStateFile.LaunchShow.none)
    }

    /// A launch that showed the run is one of the two, whether the person
    /// closed the window again or quit with it open (a quit can close it too).
    @Test func eachShownLaunchCountsWhetherClosedOrQuit() throws {
        let file = Self.stateFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try file.markProgress(.chats, interacted: true)
        try file.markNotNow()
        // Launch 2: shown, then closed again.
        #expect(Self.launch(file) == .resume(.chats))
        try file.markProgress(.chats, interacted: false)
        try file.markNotNow()
        // Launch 3: shown, then the quit closes the open window.
        #expect(Self.launch(file) == .resume(.chats))
        try file.markProgress(.chats, interacted: false)
        try file.markNotNow()
        #expect(Self.launch(file) == OnboardingStateFile.LaunchShow.none)
        #expect(Self.launch(file) == OnboardingStateFile.LaunchShow.none)
    }

    @Test func aQuitMidStepResumesRegardlessOfTheCounter() throws {
        let file = Self.stateFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try file.markProgress(.accounts, interacted: true)
        try file.markNotNow()
        #expect(Self.launch(file) == .resume(.accounts))
        // At that launch the person moves on, then quits with the window open.
        try file.markProgress(.importData, interacted: true)
        for _ in 0..<4 { #expect(Self.launch(file) == .resume(.importData)) }
    }

    @Test func skipOrDoneEndItForGoodAndOldFilesStayDone() throws {
        let file = Self.stateFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try file.markProgress(.chats, interacted: true)
        try file.markDone(completed: false)
        #expect(Self.launch(file) == OnboardingStateFile.LaunchShow.none)
        // A file written before resume existed (no finished, no counter).
        let old = #"{"version":\#(OnboardingStateFile.currentVersion),"completed":false,"date":0}"#
        try Data(old.utf8).write(to: file.url)
        #expect(Self.launch(file) == OnboardingStateFile.LaunchShow.none)
    }

    /// The close button reports "not now"; the App's rebuild does not.
    @Test func theCloseButtonIsNotNowAndARebuildIsNot() {
        let services = MockOnboardingServices()
        let controller = OnboardingWindowController(model: OnboardingModel(services: services))
        controller.window?.standardWindowButton(.closeButton)?.performClick(nil)
        #expect(services.leftNotNow == true)
        #expect(controller.window?.isVisible == false)
        let rebuilt = MockOnboardingServices()
        let other = OnboardingWindowController(model: OnboardingModel(services: rebuilt))
        other.closeForRebuild()
        #expect(rebuilt.leftNotNow == false)
        #expect(rebuilt.ended == nil)
    }

    /// Showing a step is not the person moving to it.
    @Test func onlyMovingToAStepCountsAsInteraction() {
        let services = MockOnboardingServices()
        services.canImportClassicSessions = true
        let model = OnboardingModel(services: services)
        #expect(model.steps.first == .classicSessions && model.steps.contains(.importData))
        model.go(to: .importData)
        #expect(services.reached == [.classicSessions, .importData])
        #expect(services.reachedInteracted == [false, true])
    }
}
