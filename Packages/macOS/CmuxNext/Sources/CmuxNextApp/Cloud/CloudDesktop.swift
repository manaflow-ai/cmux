import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// Open Desktop (`cloud open-desktop`): a Cloud machine's desktop in a cmux browser tab, as cmux
/// Classic shows it. The machine's noVNC (`web/services/vms/images/desktop.ts`: 6901 on its
/// loopback) loads in a Chromium tab of a new workspace on this Mac whose pane is marked as that
/// machine's (``RemoteLocalhostService/markCloudDesktop(pane:machine:)``), so the tab's localhost
/// is the machine's: its requests go through the app's peer-checked proxy and this Mac's own
/// WireGuard tunnel (enrolled with `POST /api/vm/tunnel`) to the machine's private address. No
/// port opens on this Mac, and no other program can reach the desktop.
@MainActor
enum CloudDesktop {
    /// The desktop's noVNC page on the machine's loopback: connects at once, scales to the tab,
    /// and reconnects by itself after a dropped link.
    static let url = "http://127.0.0.1:6901/vnc.html?autoconnect=1&resize=scale&reconnect=1"

    static func open(_ session: CloudMachineSession, _ context: AppActionContext) throws {
        let services = context.services, title = session.machine.title, machineID = session.machineID
        guard session.machine.allows(.desktop), session.machine.address?.ipv4 != nil else {
            throw ActionFailure(message: CloudStrings.desktopUnavailable(title))
        }
        if let reason = services.cache.browserTabs.cefUnavailableReason() { throw ActionFailure(message: reason) }
        let remote = services.remoteLocalhost, name = CloudStrings.desktopWorkspaceName(title), url = url
        // On this Mac's daemon: a Cloud machine's own daemon may predate browser tabs.
        WorkspaceHandlers.createAndShow(services: services, name: name, daemon: services.machines.local) { connection, terminal in
            guard let pane = terminal.pane else { return }
            // Marked before the tab exists, so its first load already takes the machine's route.
            await MainActor.run { remote.markCloudDesktop(pane: pane, machine: machineID) }
            _ = try await connection.newFrontendBrowserTab(url: url, engine: .cef, in: pane, title: name)
            if let surface = terminal.surface { try await connection.closeTab(surface) }
        }
    }
}
