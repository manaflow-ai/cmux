import AppKit
import CmuxCore
import SwiftUI

/// SSH Hosts section wiring for the workspace sidebar.
///
/// The section renders below the workspace rows when the
/// `sidebar.showSSHHosts` setting is on and the user's SSH config declares at
/// least one concrete host alias. Rows receive value snapshots plus closures
/// (sidebar snapshot-boundary rule); the closures capture the stores they
/// need, resolved here at body time.
extension VerticalTabsSidebar {
    private static let sshHostsDisclosureAnimation = Animation.easeInOut(duration: 0.18)

    @ViewBuilder
    var sshHostsSidebarSection: some View {
        if showSSHHostsSidebarSection, !sshHostsSidebarModel.hostAliases.isEmpty {
            let model = sshHostsSidebarModel
            let tabManager = self.tabManager
            let windowId = self.windowId
            let preferredWindow = observedWindow
            SSHHostsSidebarSection(
                items: sshHostsSidebarItems(),
                isCollapsed: model.isCollapsed,
                actions: SSHHostsSidebarSectionActions(
                    toggleCollapsed: {
                        withAnimation(Self.sshHostsDisclosureAnimation) {
                            model.isCollapsed.toggle()
                        }
                        if !model.isCollapsed {
                            model.refresh()
                        }
                    },
                    connect: { alias in
                        Self.connectToSSHHost(
                            alias: alias,
                            tabManager: tabManager,
                            windowId: windowId,
                            preferredWindow: preferredWindow
                        )
                    }
                )
            )
            .equatable()
        }
    }

    private func sshHostsSidebarItems() -> [SSHHostsSidebarItem] {
        // Track the remote-state revision so per-workspace connection
        // transitions (which do not flow through TabManager) re-derive items.
        _ = sshHostsSidebarModel.remoteStateRevision
        let activeAliases = Set(
            tabManager.tabs.compactMap { workspace -> String? in
                guard let destination = workspace.remoteConfiguration?.destination,
                      Self.isActiveRemoteConnectionState(workspace.remoteConnectionState) else {
                    return nil
                }
                return destination
            }
        )
        return sshHostsSidebarModel.hostAliases.map { alias in
            SSHHostsSidebarItem(alias: alias, isActive: activeAliases.contains(alias))
        }
    }

    /// Connects `alias` as a remote SSH workspace in the sidebar's window by
    /// launching the bundled CLI's `ssh` command — the same flow as
    /// `cmux ssh <alias>` and `ssh://` links. If this window already has a
    /// live workspace for the alias, it is selected instead of duplicated.
    @MainActor
    static func connectToSSHHost(
        alias: String,
        tabManager: TabManager,
        windowId: UUID,
        preferredWindow: NSWindow?
    ) {
        if let existing = tabManager.tabs.first(where: { workspace in
            workspace.remoteConfiguration?.destination == alias
                && isActiveRemoteConnectionState(workspace.remoteConnectionState)
        }) {
            tabManager.selectWorkspace(existing)
            return
        }
        CmuxSSHURLProcessLauncher.shared.start(
            cliArguments: ["ssh", "--window", windowId.uuidString, alias],
            destination: alias,
            failureAlertTitle: String(
                localized: "sidebar.sshHosts.connectFailedTitle",
                defaultValue: "Couldn't Connect to SSH Host"
            ),
            preferredWindow: preferredWindow
        )
    }

    /// Live means connected or with a connection attempt in flight; those
    /// states dedupe a click into selecting the existing workspace, while
    /// disconnected/error/suspended workspaces get a fresh connection.
    private static func isActiveRemoteConnectionState(_ state: WorkspaceRemoteConnectionState) -> Bool {
        switch state {
        case .connected, .connecting, .reconnecting:
            return true
        case .disconnected, .error, .suspended:
            return false
        }
    }
}
