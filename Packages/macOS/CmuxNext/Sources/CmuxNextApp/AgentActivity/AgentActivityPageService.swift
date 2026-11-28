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

    private func makeSource() -> any AgentActivitySource {
        let environment = ProcessInfo.processInfo.environment
        if services.environment.showcase || (DevTools.isEnabled && environment["CMUX_NEXT_AGENT_ACTIVITY_MOCK"] == "1") {
            return AgentActivityMockSource()
        }
        return AgentActivitySocketSource(configuration: .standard(machineName: AgentActivityPaneStrings.thisMac))
    }
}
