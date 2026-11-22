import AppKit
import Foundation
import Testing
@testable import CmuxNextOnboarding

/// Leo, 2026-10-06: the first run brings over classic cmux workspaces and
/// Claude Code and Codex chats by itself. A screen whose scan finds
/// nothing drops out instead of saying so.
@MainActor
@Suite struct FirstRunImportTests {
    func services(workspaces: Int, chats: Int) -> MockOnboardingServices {
        let services = MockOnboardingServices()
        services.accountsView = NSView()
        services.firstTaskView = NSView()
        services.canImportClassicSessions = true
        let pane = ClassicSessionLayout.pane(ClassicSessionPane(tabs: [ClassicSessionTab(workingDirectory: "/tmp", title: nil)]))
        services.classicWorkspaces = (0..<workspaces).map {
            ClassicSessionWorkspace(name: "ws\($0)", workingDirectory: "/tmp", layout: pane)
        }
        services.agentChats = (0..<chats).map {
            AgentChat(sessionID: "s\($0)", app: .claudeCode, folder: URL(fileURLWithPath: "/tmp"),
                      title: "chat \($0)", prompts: 1, lastActive: Date())
        }
        return services
    }

    func scanned(_ model: OnboardingModel) async {
        model.stepDidAppear()
        for _ in 0..<200 where !(model.chats.scanned && model.classicSessions.scanned) { await Task.yield() }
    }

    @Test func theFirstRunBringsOverWorkspacesAndChatsBeforeBrowsers() async {
        let model = OnboardingModel(services: services(workspaces: 2, chats: 3))
        await scanned(model)
        #expect(model.steps == [.accounts, .classicSessions, .chats, .importData])
        model.next()
        #expect(model.step == .classicSessions && model.classicSessions.chosen.count == 2)
        model.next()
        #expect(model.step == .chats)
    }

    @Test func aScreenWhoseScanFindsNothingDropsOut() async {
        let model = OnboardingModel(services: services(workspaces: 0, chats: 1))
        await scanned(model)
        #expect(model.steps == [.accounts, .chats, .importData])
        let empty = OnboardingModel(services: services(workspaces: 0, chats: 0))
        await scanned(empty)
        #expect(empty.steps == [.accounts, .importData])
        empty.next()
        #expect(empty.step == .importData)
    }

    @Test func importFromNewTabDropsEmptyScreensToo() async {
        let model = OnboardingModel(services: services(workspaces: 1, chats: 0), start: .projects)
        await scanned(model)
        #expect(model.steps == [.projects, .classicSessions])
    }

    /// A screen stays while it is up, even when its scan comes back empty.
    @Test func theShownScreenStays() async {
        let model = OnboardingModel(services: services(workspaces: 0, chats: 0), start: .chats)
        await scanned(model)
        #expect(model.step == .chats && model.steps.contains(.chats))
    }
}
