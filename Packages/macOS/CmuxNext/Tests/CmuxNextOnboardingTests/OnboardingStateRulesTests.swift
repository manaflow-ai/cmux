import AppKit
import Foundation
import Testing
@testable import CmuxNextOnboarding

/// The first run's state rules (onboarding phase 0, cx-aha.7): once
/// finished it stays finished, a quit counts as a shown launch, each
/// channel has its own state, and one window at a time.
@MainActor
@Suite struct OnboardingStateRulesTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "onboarding-rules-\(UUID().uuidString)")
    }

    /// Each launch is a new instance reading the same file.
    static func launch(_ file: OnboardingStateFile) -> OnboardingStateFile.LaunchShow {
        OnboardingStateFile(url: file.url).takeLaunchShow()
    }

    /// Done, then Continue Setup: the reopened first run shows its saved
    /// step and the person moves in it, but onboarding stays finished.
    @Test func continueSetupAfterDoneKeepsFinished() throws {
        let root = Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = OnboardingStateFile(url: root.appending(path: "onboarding.json"))
        #expect(Self.launch(file) == .start)
        try file.markProgress(.accounts, interacted: false)
        try file.markProgress(.importData, interacted: true)
        try file.markDone(completed: true)
        #expect(file.resumeStep() == .importData, "Continue Setup reopens at the saved step")
        // The Continue Setup window shows its step, then the person moves.
        try file.markProgress(.importData, interacted: false)
        try file.markProgress(.chats, interacted: true)
        #expect(!file.needsOnboarding())
        #expect(Self.launch(file) == OnboardingStateFile.LaunchShow.none)
        #expect(file.resumeStep() == .chats)
    }

    /// Skip ends it the same way.
    @Test func continueSetupAfterSkipKeepsFinished() throws {
        let root = Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = OnboardingStateFile(url: root.appending(path: "onboarding.json"))
        try file.markProgress(.accounts, interacted: false)
        try file.markDone(completed: false)
        try file.markProgress(.accounts, interacted: false)
        #expect(Self.launch(file) == OnboardingStateFile.LaunchShow.none)
    }

    /// Cmd-Q with the first run open closes no window. The launch that
    /// showed it still counts: it shows on the next two launches only.
    @Test func quitDuringFirstRunCountsAsNotNow() throws {
        let root = Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = OnboardingStateFile(url: root.appending(path: "onboarding.json"))
        #expect(Self.launch(file) == .start)
        try file.markProgress(.accounts, interacted: false)
        // Quit: nothing is recorded.
        #expect(Self.launch(file) == .resume(.accounts))
        try file.markProgress(.accounts, interacted: false)
        #expect(Self.launch(file) == .resume(.accounts))
        try file.markProgress(.accounts, interacted: false)
        #expect(Self.launch(file) == OnboardingStateFile.LaunchShow.none)
        #expect(Self.launch(file) == OnboardingStateFile.LaunchShow.none)
    }

    /// Release, nightly and each dev tag keep their own state; release
    /// keeps the state of the file all builds shared before.
    @Test func stateIsScopedPerChannel() throws {
        let support = Self.directory()
        defer { try? FileManager.default.removeItem(at: support) }
        func live(_ bundleID: String?) -> OnboardingStateFile {
            OnboardingStateFile.live(environment: [:], bundleID: bundleID, supportDirectory: support)
        }
        let release = live("com.cmuxterm.app"), nightly = live("com.cmuxterm.app.nightly")
        let dev = live("com.cmuxterm.app.debug.onbst"), otherDev = live("com.cmuxterm.app.debug.other")
        #expect(Set([release.url, nightly.url, dev.url, otherDev.url, live(nil).url]).count == 5)
        try dev.markDone(completed: false)
        #expect(!live("com.cmuxterm.app.debug.onbst").needsOnboarding())
        #expect(live("com.cmuxterm.app.nightly").needsOnboarding(), "Skip in DEV does not hide NIGHTLY onboarding")
        #expect(otherDev.needsOnboarding())
        // The old shared file (written before channels had their own).
        let legacy = support.appending(path: "cmux/onboarding.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":\#(OnboardingStateFile.currentVersion),"completed":true,"date":0,"finished":true}"#.utf8).write(to: legacy)
        #expect(!live("com.cmuxterm.app").needsOnboarding(), "release keeps its state")
        #expect(live("com.cmuxterm.app.nightly").needsOnboarding())
        #expect(live("com.cmuxterm.app.rc").needsOnboarding())
    }

    static func presenter(_ services: MockOnboardingServices, made: @escaping (OnboardingModel) -> Void) -> OnboardingWindowPresenter {
        OnboardingWindowPresenter(makeModel: { start, resume in
            let model = OnboardingModel(services: services, start: start, resumingFirstRunAt: resume)
            made(model)
            return model
        }, present: { _ in })
    }

    /// Continue Setup with the first run open brings that window forward:
    /// same window, same step, nothing typed in it lost.
    @Test func continueSetupReusesOpenFirstRunWindow() {
        let services = MockOnboardingServices()
        services.accountsView = NSView()
        services.canImportClassicSessions = true
        var models: [OnboardingModel] = []
        let presenter = Self.presenter(services) { models.append($0) }
        presenter.showFirstRun(resumingAt: nil)
        let first = presenter.controller
        first?.model.go(to: .classicSessions)
        presenter.showFirstRun(resumingAt: .accounts)
        #expect(models.count == 1)
        #expect(presenter.controller === first)
        #expect(first?.model.step == .classicSessions)
        #expect(first?.model.ended == false)
    }

    /// A rebuild whose closing window brings the first run back (it had
    /// interrupted it) leaves exactly one open window, the tracked one.
    @Test func reentrantShowKeepsOneWindow() {
        let services = MockOnboardingServices()
        services.accountsView = NSView()
        var models: [OnboardingModel] = []
        let presenter = Self.presenter(services) { models.append($0) }
        presenter.showFirstRun(resumingAt: nil)
        // Import and Sync interrupts the first run.
        presenter.show(step: .projects)
        // A step that group does not have rebuilds the window again.
        presenter.show(step: .theme)
        let open = models.filter { !$0.ended }
        #expect(open.count == 1)
        #expect(open.first === presenter.controller?.model)
        #expect(presenter.controller?.model.steps.contains(.theme) == true)
        // Closing it brings back the interrupted first run, once.
        presenter.controller?.closeWithCloseButton()
        #expect(models.filter { !$0.ended }.count == 1)
        #expect(presenter.controller?.model.isFirstRun == true)
    }

    /// One serial writer: writes apply in the order asked for, and a read
    /// sees every write queued before it. Each write replaces the file
    /// whole and leaves no temporary file.
    @Test func stateWritesAreOrderedAndAtomic() async throws {
        let root = Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = OnboardingStateQueue(file: OnboardingStateFile(url: root.appending(path: "onboarding.json")))
        let steps: [OnboardingModel.Step] = [.accounts, .classicSessions, .chats, .importData]
        for index in 0..<40 {
            let step = steps[index % steps.count]
            queue.write("progress") { try $0.markProgress(step, interacted: true) }
        }
        #expect(await queue.perform { $0.resumeStep() } == steps[39 % steps.count])
        queue.write("done") { try $0.markDone(completed: true) }
        #expect(await queue.perform { $0.needsOnboarding() } == false)
        await queue.drain()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names == ["onboarding.json"])
    }
}
