import AppKit
import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextComputerUse
import CmuxNextDaemon

/// The App's ``ComputerUseFocusing``: the target app by pid,
/// the calling terminal through the same reveal as a tab link.
@MainActor
final class AppComputerUseFocus: ComputerUseFocusing {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    func raiseTarget(of session: ComputerUseLiveSession) -> Bool {
        guard let target = session.target else { return false }
        // The host reports the pid it acted on; a recycled pid of another app is refused by the bundle id.
        guard let pid = target.pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              target.bundleID == nil || app.bundleIdentifier == target.bundleID else { return false }
        return app.activate(options: [])
    }

    func revealCallingTerminal(of session: ComputerUseLiveSession) -> Bool {
        guard let services, let terminal = session.terminalID else { return false }
        for daemon in services.machines.daemons {
            let store = daemon.store
            if let tab = store.tab(terminal: TerminalID(rawValue: terminal)) ?? store.tab(terminalResource: ResourceID(rawValue: terminal)) {
                return services.revealTab(tab.id)
            }
        }
        return false
    }
}

/// Computer use's live preview card (``ComputerUseLivePreview``) in the App's agent chats.
extension AgentTabStore {
    /// Every agent chat with a page, with what links it to a Computer Use session.
    func computerUsePreviewChats() -> [ComputerUsePreviewChat] {
        ComputerUsePreviewChat.chats(keys: views.keys, session: session(of:), lanes: AgentLaneStore.shared.lanes)
    }

    /// Shows `card` (nil: none) in chat tab `chat`'s page; a click on it goes to `respond`.
    func showComputerUsePreview(_ card: ComputerUsePreviewCard?, in chat: String,
                                respond: @escaping @MainActor (String, ComputerUsePreviewClick) -> Void) {
        guard let view = views[chat] else { return }
        let preview = card.map {
            AgentPaneComputerUsePreview(session: $0.session, app: $0.app, done: $0.done, frame: $0.frame, icon: $0.icon,
                                        pointer: $0.pointer.map { .init(x: $0.x, y: $0.y, click: $0.click, windowWidth: $0.windowWidth) })
        }
        AgentPaneComputerUsePreview.show(preview, on: view) { session, action in
            if let click = ComputerUsePreviewClick(rawValue: action.rawValue) { respond(session, click) }
        }
    }
}
