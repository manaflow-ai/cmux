import Foundation

final class CmuxSidebarExtensionRuntime<Extension: CmuxSidebarExtension>: @unchecked Sendable {
    private let sidebarExtension: Extension
    private let connection: CMUXSidebarExtensionConnection

    @MainActor
    init(sidebarExtension: Extension) {
        self.sidebarExtension = sidebarExtension
        var transport: CMUXSidebarExtensionConnection!
        transport = CMUXSidebarExtensionConnection(
            manifest: Extension.manifest,
            onSnapshot: { [weak sidebarExtension] snapshot in
                let host = CmuxSidebarHost(
                    performCancellableAction: { action, reply in
                        transport.perform(action, reply: reply)
                    },
                    refreshSnapshot: {
                        transport.refreshSnapshot()
                    }
                )
                sidebarExtension?.update(context: CmuxSidebarContext(snapshot: snapshot, host: host))
            },
            onError: { [weak sidebarExtension] message in
                sidebarExtension?.connectionErrorDidChange(message)
            }
        )
        self.connection = transport
    }

    @discardableResult
    func accept(_ connection: NSXPCConnection) -> Bool {
        self.connection.accept(connection)
    }
}
