import Foundation

extension AppDelegate {
    func prepareRemoteSessionsForSystemSleep() {
        forEachRemoteWorkspace { workspace in
            workspace.prepareRemoteSessionForSystemSleep()
        }
    }

    func rearmRemoteSessionsAfterSystemWake() {
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
