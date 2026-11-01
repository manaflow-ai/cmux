import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextComputerUse
import Foundation

/// Opens `cmux://agent-activity` (plans/cmux-next/computer-use.md section 7)
/// and makes its pages. Each page reads the local CUA host through
/// `AgentActivitySocketSource`; DEV and NIGHTLY builds can use the demo data
/// with `CMUX_NEXT_AGENT_ACTIVITY_MOCK=1`.
@MainActor
final class AgentActivityPageService {
    private unowned let services: AppServices
    /// A jump waiting for its workspace's first pane (`open(_:in:)`); the next jump cancels it.
    private var paneWait: Task<Void, Never>?
    /// Counts jumps, so a workspace that mounts after a newer jump opens nothing.
    private var jumps = 0
    /// The pages made, weakly held, so a live preview card's click selects its session in them.
    private let pages = NSHashTable<AgentActivityPageTab>.weakObjects()
    /// The session the next page made selects (``open(session:)`` opened a new tab).
    private var pendingSelection: String?

    init(services: AppServices) {
        self.services = services
    }

    /// Selects the active window's Agent activity tab, else opens one beside
    /// the focused tab.
    func open() {
        _ = openTab()
    }

    /// ``open()``: true only when it opened a new tab.
    private func openTab() -> Bool {
        guard let window = services.windows.active else {
            services.registry.refuse(RefusalStrings.noWindowOpen)
            return false
        }
        for pane in window.content?.panes.values.map({ $0 }) ?? [] {
            if let tab = pane.pane.tabs.first(where: { AgentActivityPageAddress.matches($0.url.flatMap(URL.init(string:))) }) {
                pane.select(StripTabID(tab.id))
                return false
            }
        }
        guard let pane = window.focusedPane else { return false }
        pane.newBrowserTab(url: AgentActivityPageAddress.url)
        return true
    }

    /// Opens Agent Activity (``open()``) on Computer Use session `session`: the live preview card's
    /// click. An open page selects it now; a page this opens selects it as it is made. When no page
    /// opens, nothing waits, so a page made later never selects this old session.
    func open(session: String) {
        for page in pages.allObjects { page.model.select(session: session) }
        pendingSelection = session
        if !openTab() { pendingSelection = nil }
    }

    func makePage(key: String, engine: BrowserEngineKind, profile: BrowserProfileID) -> AgentActivityPageTab {
        let page = AgentActivityPageTab(id: BrowserTabID(rawValue: key), engine: engine, profile: profile, source: makeSource())
        pages.add(page)
        if let session = pendingSelection {
            pendingSelection = nil
            page.model.select(session: session)
        }
        return page
    }

    /// Shows a lane's chat where ``AgentChatJump`` says it lives. Back returns
    /// to where the person jumped from, so a pick is never a dead end.
    func jump(to lane: AgentActivityLane) {
        let jump = AgentChatJump.decide(lane: lane, shownIn: services.agentTabs.tab(showing: lane.id),
                                        hasWorkspace: { [services] in services.workspace(id: $0) != nil })
        // The next settled location is its own step, even within one workspace.
        services.locationTrail.noteJump()
        jumps += 1
        paneWait?.cancel()
        paneWait = nil
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
        let jump = jumps
        services.windows.afterNextContent(in: window, showing: workspaceID) { [weak self, weak window] in
            guard let self, let window, jumps == jump else { return }
            open(session, in: window)
        }
    }

    private func open(_ session: String, in window: WindowController) {
        if let pane = window.focusedPane { return pane.openAgentSession(session) }
        guard let workspaceID = window.content?.workspace.id else { return services.registry.refuse(MiscHandlerStrings.noPane) }
        // The workspace shows before its panes mount: open the chat in the first one. The wait
        // ends when a pane mounts, when the window closes or shows another workspace, or when
        // the next pick replaces it. The registry and the window's state are observable, so
        // closing the window or showing another workspace (even one already mounted, which
        // mounts nothing) ends the wait at once.
        let windows = services.windows, mounts = services.paneMounts, state = window.state, windowID = window.state.id
        paneWait = Task { [weak self] in
            for await next in ObservationStream({ () -> AgentChatJump.PaneWait in
                _ = mounts.generation
                let open = windows.registry.value.window(windowID)?.isOpen == true
                let window = windows.controller(for: windowID)
                let mounted = window?.content?.workspace.id == workspaceID && window?.focusedPane != nil
                return .decide(showing: open ? state.workspaceID : nil, workspaceID: workspaceID, hasPane: mounted)
            }) where next != .wait {
                if next == .open, !Task.isCancelled { windows.controller(for: windowID)?.focusedPane?.openAgentSession(session) }
                break
            }
            if !Task.isCancelled { self?.paneWait = nil }
        }
    }

    /// The `cmux://session/<id>` path every session link takes: the focused pane
    /// of the active window.
    private func openInFocusedPane(_ session: String) {
        do {
            try DeepLinkNavigator(services: services).open(DeepLink(.session(session, turn: nil)), background: false, asking: false)
        } catch {
            services.registry.refuse(String(describing: error))
        }
    }

    private func makeSource() -> any AgentActivitySource {
        let environment = ProcessInfo.processInfo.environment
        if services.environment.showcase || (DevTools.isEnabled && environment["CMUX_NEXT_AGENT_ACTIVITY_MOCK"] == "1") {
            return AgentActivityMockSource()
        }
        return AgentActivitySocketSource(configuration: {
            guard var configuration = ComputerUseHelperDaemon.shared.configuration else { return nil }
            configuration.machineName = AgentActivityPaneStrings.thisMac
            return configuration
        })
    }
}
