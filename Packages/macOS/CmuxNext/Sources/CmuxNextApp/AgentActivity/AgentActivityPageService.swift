import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextBridge
import CmuxNextBrowser
import Foundation

/// Opens `cmux://agent-activity` (plans/cmux-next/computer-use.md section 7)
/// and makes its pages. Each page reads the local CUA host through
/// `AgentActivitySocketSource`; DEV and NIGHTLY builds can use the demo data
/// with `CMUX_NEXT_AGENT_ACTIVITY_MOCK=1`.
@MainActor
final class AgentActivityPageService {
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// Selects the active window's Agent activity tab, else opens one beside
    /// the focused tab.
    func open() {
        guard let window = services.windows.active else { return services.registry.refuse(RefusalStrings.noWindowOpen) }
        for pane in window.content?.panes.values.map({ $0 }) ?? [] {
            if let tab = pane.pane.tabs.first(where: { AgentActivityPageAddress.matches($0.url.flatMap(URL.init(string:))) }) {
                pane.select(StripTabID(tab.id))
                return
            }
        }
        guard let pane = window.focusedPane else { return }
        pane.newBrowserTab(url: AgentActivityPageAddress.url)
    }

    func makePage(key: String, engine: BrowserEngineKind, profile: BrowserProfileID) -> AgentActivityPageTab {
        AgentActivityPageTab(id: BrowserTabID(rawValue: key), engine: engine, profile: profile, source: makeSource())
    }

    /// Shows a lane's chat where ``AgentChatJump`` says it lives. Back returns
    /// to where the person jumped from, so a pick is never a dead end.
    func jump(to lane: AgentActivityLane) {
        let jump = AgentChatJump.decide(lane: lane, shownIn: services.agentTabs.tab(showing: lane.id),
                                        hasWorkspace: { [services] in services.workspace(id: $0) != nil })
        // The next settled location is its own step, even within one workspace.
        services.locationTrail.noteJump()
        switch jump {
        case .revealTab(let key):
            if !services.revealTab(key, intent: .raise) { openInFocusedPane(lane.id) }
        case .openInWorkspace(let workspaceID, let session):
            open(session, inWorkspace: workspaceID)
        case .openInFocusedPane(let session):
            openInFocusedPane(session)
        }
    }

    /// Shows the workspace where it lives, then opens the chat in a pane there,
    /// so the jump never replaces what the person is looking at. A workspace no
    /// window can show falls back to the focused pane.
    private func open(_ session: String, inWorkspace workspaceID: String) {
        guard let window = services.windows.reveal(workspaceID: workspaceID), let nsWindow = window.window else {
            return openInFocusedPane(session)
        }
        services.showJumpWindow(nsWindow, .raise)
        guard window.content?.workspace.id != workspaceID else { return open(session, in: window) }
        // It has to mount that workspace's panes first.
        services.windows.afterNextContent(in: window, showing: workspaceID) { [weak self, weak window] in
            guard let window else { return }
            self?.open(session, in: window)
        }
    }

    private func open(_ session: String, in window: WindowController) {
        guard let pane = window.focusedPane else { return services.registry.refuse(MiscHandlerStrings.noPane) }
        pane.openAgentSession(session)
    }

    /// The `cmux://session/<id>` path every session link takes: the focused pane
    /// of the active window.
    private func openInFocusedPane(_ session: String) {
        do {
            try DeepLinkNavigator(services: services).open(DeepLink(.session(session, turn: nil)), background: false)
        } catch {
            services.registry.refuse(String(describing: error))
        }
    }

    private func makeSource() -> any AgentActivitySource {
        let environment = ProcessInfo.processInfo.environment
        if services.environment.showcase || (DevTools.isEnabled && environment["CMUX_NEXT_AGENT_ACTIVITY_MOCK"] == "1") {
            return AgentActivityMockSource()
        }
        return AgentActivitySocketSource(configuration: .standard(machineName: AgentActivityPaneStrings.thisMac))
    }
}
