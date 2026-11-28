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
        // The title action is for an open (live) page: a card alone is no live tab.
        let context = TerminalTabContext(safeAreaInsets: .init(), isInteractive: true,
                                         isZoomGestureActive: false, reportScroll: { _ in })
        source.prepareCard(for: tab, in: workspace)
        _ = source.page(for: tab, in: workspace, context: context)
        let direct = try #require(source.titleAction(for: tab, in: workspace))
        #expect(!direct.isSelected)
        // The tap rebuilds the page on a new session (`TerminalSessionChoice` reads the
        // choice), whatever Re-wrap on Phone is set to.
        let before = try #require(source.model(forTabID: tab.id))
        direct.perform()
        #expect(TerminalFitToPhoneMemory().fitToPhone(for: program))
        #expect(source.model(forTabID: tab.id) !== before)
        #expect(source.titleAction(for: tab, in: workspace)?.isSelected == true)

        // Recreating the host reads the saved choice, and the original menu
        // reverses the same action without its own preference or mutation path.
        source.reset()
        source.prepareCard(for: tab, in: workspace)
        _ = source.page(for: tab, in: workspace, context: context)
        #expect(source.titleAction(for: tab, in: workspace)?.isSelected == true)
        let fitted = try #require(source.model(forTabID: tab.id))
        let menu = try #require(source.actions(for: tab, in: workspace).first { $0.title == direct.title })
        menu.perform()
        #expect(!TerminalFitToPhoneMemory().fitToPhone(for: program))
        #expect(source.model(forTabID: tab.id) !== fitted)
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
