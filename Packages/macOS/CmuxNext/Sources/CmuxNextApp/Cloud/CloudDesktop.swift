import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextRemoteLocalhostService
import Foundation

/// Open Desktop (`cloud open-desktop`): a Cloud machine's desktop in a cmux browser tab, as cmux
/// Classic shows it. The machine's noVNC (`web/services/vms/images/desktop.ts`: 6901 on its
/// loopback) loads in a Chromium tab of a new workspace on this Mac, at a URL that names the
/// machine (``RemoteLocalhostService/cloudDesktopURL(machine:)``). Remote localhost routes that
/// page by its URL: its requests go through the app's peer-checked proxy and this Mac's own
/// WireGuard tunnel (enrolled with `POST /api/vm/tunnel`) to the machine's private address, with
/// no TCP port opened on this Mac; without the tunnel the page stays blank, never this Mac's.
@MainActor
enum CloudDesktop {
    static func open(_ session: CloudMachineSession, _ context: AppActionContext) throws {
        let services = context.services, title = session.machine.title
        guard session.machine.allows(.desktop), session.machine.address?.ipv4 != nil,
              let url = RemoteLocalhostService.cloudDesktopURL(machine: session.machineID) else {
            throw ActionFailure(message: CloudStrings.desktopUnavailable(title))
        }
        if let reason = services.cache.browserTabs.cefUnavailableReason() { throw ActionFailure(message: reason) }
        let name = CloudStrings.desktopWorkspaceName(title), address = url.absoluteString
        // On this Mac's daemon: a Cloud machine's own daemon may predate browser tabs.
        WorkspaceHandlers.createAndShow(services: services, name: name, daemon: services.machines.local) { connection, terminal in
            guard let pane = terminal.pane else { return }
            _ = try await connection.newFrontendBrowserTab(url: address, engine: .cef, in: pane, title: name)
            if let surface = terminal.surface { try await connection.closeTab(surface) }
        }
    }
}
