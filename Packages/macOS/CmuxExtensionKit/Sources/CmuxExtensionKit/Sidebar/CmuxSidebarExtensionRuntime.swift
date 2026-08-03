import Foundation

/// Runtime bridge between one sidebar extension instance and its XPC connection.
///
/// `@unchecked Sendable` is safe here because the only stored state is the
/// lock-protected `CMUXSidebarExtensionConnection`. The extension instance is
/// captured weakly inside `@MainActor` callbacks and is not stored on this type.
final class CmuxSidebarExtensionRuntime: @unchecked Sendable {
    private let connection: CMUXSidebarExtensionConnection

    @MainActor
    init<Extension: CmuxSidebarExtension>(sidebarExtension: Extension) {
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
            onStatus: { [weak sidebarExtension] status in
                sidebarExtension?.connectionStatusDidChange(status)
            },
            presentationProvider: { [weak sidebarExtension] in
                sidebarExtension?.presentation ?? CmuxSidebarPresentation(root: .empty)
            },
            presentationActionHandler: { [weak sidebarExtension] actionID in
                await sidebarExtension?.handlePresentationAction(actionID)
            }
        )
        self.connection = transport
    }

    @discardableResult
    func accept(_ connection: NSXPCConnection) -> Bool {
        self.connection.accept(connection)
    }

    deinit {
        connection.invalidate()
    }
}
