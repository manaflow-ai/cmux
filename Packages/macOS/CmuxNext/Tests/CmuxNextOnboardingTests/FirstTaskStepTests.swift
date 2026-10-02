import AppKit
import Foundation
import Testing
@testable import CmuxNextOnboarding

/// The first-task step: a real chat in `~/cmux/first-task` (a temporary
/// folder here), the task's prompt, and the files it saves.
@MainActor
@Suite struct FirstTaskStepTests {
    /// File work runs off the main thread; wait for it (bounded).
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func services() -> MockOnboardingServices {
        let services = MockOnboardingServices()
        services.firstTaskView = NSView()
        return services
    }

    @Test func theStepFollowsRoleOnlyWhenTheAppCanRunAChat() {
        #expect(!OnboardingModel(services: MockOnboardingServices()).steps.contains(.firstTask))
        let model = OnboardingModel(services: services())
        #expect(model.steps == [.role, .firstTask, .defaultBrowser, .importData, .theme])
        model.next()
        #expect(model.step == .firstTask)
    }

    @Test func theChartTaskGetsTheSampleSheetAndTheChatItsFolderAndPrompt() async throws {
        let services = services()
        let model = OnboardingModel(services: services, start: .firstTask)
        let folder = model.firstTask.folder.url
        defer { try? FileManager.default.removeItem(at: folder) }
        model.firstTask.pick(.chart)
        model.firstTask.pick(.note)
        await settle { model.firstTask.task != nil }
        #expect(model.firstTask.task == .chart, "the first pick wins")
        let sheet = try String(contentsOf: folder.appending(path: "sales.csv"), encoding: .utf8)
        #expect(sheet.hasPrefix("month,revenue,orders"))

        let view = FirstTaskStepView(model: model.firstTask, services: services)
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 300)
        view.layoutSubtreeIfNeeded()
        #expect(services.firstTaskRequests.count == 1)
        #expect(services.firstTaskRequests.first?.cwd == folder)
        #expect(services.firstTaskRequests.first?.prompt == OnboardingStrings.firstTaskPrompt(.chart))
        #expect(services.firstTaskView?.superview != nil, "the chat replaces the cards")
    }

    /// Saved files show up as they land, newest first; the sample is input,
    /// and a file from an earlier run is not this run's output.
    @Test func savedFilesAppearWithoutTheSampleOrEarlierRuns() async throws {
        let services = services()
        let model = OnboardingModel(services: services, start: .firstTask)
        let folder = model.firstTask.folder.url
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let earlier = folder.appending(path: "welcome-note.md")
        try Data("hi".utf8).write(to: earlier)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: earlier.path)
        model.firstTask.pick(.chart)
        await settle { model.firstTask.task != nil }
        #expect(model.firstTask.outputs.isEmpty)
        try Data("<svg/>".utf8).write(to: folder.appending(path: "chart.svg"))
        await settle { !model.firstTask.outputs.isEmpty }
        #expect(model.firstTask.outputs.map(\.lastPathComponent) == ["chart.svg"])

        let chart = try #require(model.firstTask.outputs.first)
        model.firstTask.open(chart)
        model.firstTask.reveal(chart)
        #expect(services.opened == [chart] && services.revealed == [chart])
    }

    @Test func theNoteTaskWritesNothingAndSkipCreatesNoFolder() async {
        let skipped = OnboardingModel(services: services(), start: .firstTask)
        skipped.skipStep()
        #expect(skipped.step == .defaultBrowser)
        #expect(!FileManager.default.fileExists(atPath: skipped.firstTask.folder.url.path))

        let model = OnboardingModel(services: services(), start: .firstTask)
        let folder = model.firstTask.folder.url
        defer { try? FileManager.default.removeItem(at: folder) }
        model.firstTask.pick(.note)
        await settle { model.firstTask.task != nil }
        #expect(model.firstTask.folder.outputs().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "sales.csv").path))
    }

    /// The live folder stays out of Desktop, Documents and Downloads (no privacy prompt).
    @Test func theLiveFolderIsInTheHomeCmuxFolder() {
        let live = FirstTaskFolder.live(environment: [:]).url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        #expect(live == home + "/cmux/first-task")
        #expect(FirstTaskFolder.live(environment: [FirstTaskFolder.environmentKey: "/tmp/x"]).url.path == "/tmp/x")
    }

    @Test func everyTaskHasItsOwnCopy() {
        let names = FirstTask.allCases.map(OnboardingStrings.firstTaskName)
        let prompts = FirstTask.allCases.map(OnboardingStrings.firstTaskPrompt)
        #expect(Set(names).count == names.count && Set(prompts).count == prompts.count)
        let blank = (names + prompts).filter { $0.isEmpty }
        #expect(blank.isEmpty)
    }
}
