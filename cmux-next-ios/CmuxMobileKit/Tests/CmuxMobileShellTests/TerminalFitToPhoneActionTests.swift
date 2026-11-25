#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileTerminal
import CmuxMobileWorkspaces
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor @Suite struct TerminalFitToPhoneActionTests {
    @Test func directActionAndMenuRebuildTheSessionAndRememberTheProgram() throws {
        let program = "fit-action-\(UUID().uuidString)"
        let key = TerminalFitToPhoneMemory.keyPrefix + program
        defer { UserDefaults.standard.removeObject(forKey: key) }
        TerminalFitToPhoneMemory().set(false, for: program)
        let source = GhosttyTerminalTabContent()
        source.frameStore = nil
        source.drafts = nil
        defer { source.reset() }
        source.sessionProvider = { _, _ in FitActionSession(programName: program) }
        let workspace = try #require(AppStore.mock().workspaces.first { $0.tabs.contains { $0.kind == .terminal } })
        let tab = try #require(workspace.tabs.first { $0.kind == .terminal })
        source.prepareCard(for: tab, in: workspace)
        let direct = try #require(source.titleAction(for: tab, in: workspace))
        #expect(!direct.isSelected)
        #expect(source.model(forTabID: tab.id)?.session is TerminalProjectingSession)
        direct.perform()
        #expect(TerminalFitToPhoneMemory().fitToPhone(for: program))
        #expect(source.model(forTabID: tab.id)?.session is FitActionSession)
        #expect(source.titleAction(for: tab, in: workspace)?.isSelected == true)

        // Recreating the host reads the saved choice, and the original menu
        // reverses the same action without its own preference or mutation path.
        source.reset()
        source.prepareCard(for: tab, in: workspace)
        #expect(source.model(forTabID: tab.id)?.session is FitActionSession)
        let menu = try #require(source.actions(for: tab, in: workspace).first { $0.title == direct.title })
        menu.perform()
        #expect(!TerminalFitToPhoneMemory().fitToPhone(for: program))
        #expect(source.model(forTabID: tab.id)?.session is TerminalProjectingSession)
        #expect(source.titleAction(for: tab, in: workspace)?.isSelected == false)
    }
}

@MainActor private final class FitActionSession: TerminalSession {
    let programName: String
    let isAlternateScreen = false
    init(programName: String) { self.programName = programName }
    func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {}
    func send(_ bytes: Data) {}
    func resize(columns: Int, rows: Int) {}
    func stop() {}
}
#endif
