import Foundation

extension AppDelegate {
    func prepareRemoteSessionsForSystemSleep() {
        forEachRemoteWorkspace { workspace in
            workspace.prepareRemoteSessionForSystemSleep()
        }
    }

    func rearmRemoteSessionsAfterSystemWake() {
        // `DisableRemoteConnections` (MDM): a profile that landed while the
        // Mac slept must not be pre-empted by the wake re-arm; the enforcement
        // observer disconnects these workspaces on its next re-evaluation.
        guard ManagedRemoteConnectionsPolicy.isEnabled else { return }
        forEachRemoteWorkspace { workspace in
            workspace.rearmRemoteSessionAfterSystemWake()
        }
    }

    private func forEachRemoteWorkspace(_ body: (Workspace) -> Void) {
        var seenManagers = Set<ObjectIdentifier>()
        let managers = [tabManager].compactMap { $0 } + allMainWindowTabManagersForDebug()
        for manager in managers where seenManagers.insert(ObjectIdentifier(manager)).inserted {
            for workspace in manager.tabs where workspace.isRemoteWorkspace {
                body(workspace)
            }
        }
    }
}
