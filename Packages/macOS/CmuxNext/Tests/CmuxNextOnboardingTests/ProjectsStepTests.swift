import AppKit
import Foundation
import Testing
@testable import CmuxNextOnboarding

/// The projects step: the scan's best projects come checked, Continue opens
/// the checked ones, Skip opens nothing, and a folder picker appears only
/// when nothing was found.
@MainActor
@Suite struct ProjectsStepTests {
    func project(_ path: String, _ sessions: Int = 3) -> AgentProject {
        AgentProject(folder: URL(fileURLWithPath: path, isDirectory: true), sessions: sessions, lastActive: Date(), apps: [.claudeCode])
    }

    func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    func model(_ projects: [AgentProject]) async -> (OnboardingModel, MockOnboardingServices) {
        let services = MockOnboardingServices()
        services.agentProjects = projects
        let model = OnboardingModel(services: services)
        model.stepDidAppear()
        await settle { model.projects.scanned }
        return (model, services)
    }

    @Test func projectsFollowRoleAndTheScanStartsOnTheRoleStep() async {
        let (model, _) = await model([project("/Users/demo/code/app")])
        #expect(model.steps.prefix(2) == [.role, .projects])
        #expect(model.projects.projects.count == 1)
    }

    @Test func theBestFiveComeCheckedAndContinueOpensThemInOrder() async {
        let paths = (0..<7).map { "/Users/demo/code/p\($0)" }
        let (model, services) = await model(paths.map { project($0) })
        #expect(model.projects.chosen.map(\.path) == Array(paths.prefix(5)))
        model.projects.toggle(model.projects.projects[1])
        model.projects.toggle(model.projects.projects[6])
        model.go(to: .projects)
        model.next()
        #expect(services.openedProjects == [[paths[0], paths[2], paths[3], paths[4], paths[6]].map { URL(fileURLWithPath: $0, isDirectory: true) }])
        #expect(model.step == .defaultBrowser)
    }

    @Test func skipAndAnEmptyChoiceOpenNothing() async {
        let (skipped, skipping) = await model([project("/Users/demo/code/app")])
        skipped.go(to: .projects)
        skipped.skipStep()
        #expect(skipping.openedProjects.isEmpty && skipped.step == .defaultBrowser)

        let (cleared, clearing) = await model([project("/Users/demo/code/app")])
        cleared.projects.toggle(cleared.projects.projects[0])
        cleared.go(to: .projects)
        cleared.next()
        #expect(clearing.openedProjects.isEmpty)
    }

    @Test func nothingFoundOffersAFolderThatJoinsCheckedFirst() async {
        let (model, services) = await model([])
        #expect(model.projects.scanned && model.projects.projects.isEmpty)
        services.chosenFolder = URL(fileURLWithPath: "/Users/demo/thesis", isDirectory: true)
        model.projects.chooseFolder()
        await settle { !model.projects.projects.isEmpty }
        #expect(model.projects.chosen.map(\.path) == ["/Users/demo/thesis"])
        // A dropped folder already listed is checked, not listed twice.
        model.projects.toggle(model.projects.projects[0])
        model.projects.add(URL(fileURLWithPath: "/Users/demo/thesis/", isDirectory: true))
        #expect(model.projects.projects.count == 1 && model.projects.chosen.count == 1)
    }

    /// One line names every guarded folder among the checked projects, in a fixed order.
    @Test func guardedFoldersAreNamedOnceForTheCheckedProjects() async {
        let (model, _) = await model([project("/Users/demo/Documents/thesis"), project("/Users/demo/Desktop/a"),
                                      project("/Users/demo/Desktop/b"), project("/Users/demo/code/app")])
        #expect(model.projects.privacyFolders == [.desktop, .documents])
        model.projects.toggle(model.projects.projects[0])
        #expect(model.projects.privacyFolders == [.desktop])
        #expect(OnboardingStrings.projectsPrivacy([.desktop, .documents]).contains("Desktop"))
    }

    @Test func aRowShowsTheFolderUnderHomeAndItsUsage() {
        let home = URL(fileURLWithPath: "/Users/demo", isDirectory: true)
        #expect(ProjectRow.shortPath(URL(fileURLWithPath: "/Users/demo/code/app"), home: home) == "~/code/app")
        #expect(ProjectRow.shortPath(URL(fileURLWithPath: "/Volumes/work/app"), home: home) == "/Volumes/work/app")
        #expect(ProjectRow.shortPath(URL(fileURLWithPath: "/Users/demolition/app"), home: home) == "/Users/demolition/app")
        let used = AgentProject(folder: URL(fileURLWithPath: "/Users/demo/code/app"), sessions: 148, lastActive: Date(), apps: [.claudeCode, .codex])
        let line = ProjectRow.usage(used, now: Date())
        #expect(line.hasPrefix(148.formatted(.number)) && line.contains("Claude Code") && line.contains("Codex"))
        #expect(ProjectRow.usage(AgentProject(folder: home, sessions: 0, lastActive: Date(), apps: []), now: Date()).isEmpty)
    }
}
