import AppKit
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
