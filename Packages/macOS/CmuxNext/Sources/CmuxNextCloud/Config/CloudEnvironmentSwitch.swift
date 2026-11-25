import CmuxNextDaemon
import Foundation

/// Native lifecycle adapter after Rust has persisted a selection.
@MainActor public final class CloudEnvironmentSwitch {
    private var pending: Task<Bool, Error>?

    public init() {}

    public func apply(selected: CloudRuntimeSelection, name: String, namespace: String,
                      bootstrap: CloudEnvironmentBootstrap,
                      signOut: @escaping @MainActor () async -> Void,
                      stopServices: @escaping @MainActor () -> Void,
                      stopDaemon: @escaping @MainActor () async throws -> Void) throws -> Task<Bool, Error> {
        guard pending == nil else { throw DaemonError.launchFailed("A Cloud environment change is already in progress.") }
        let task = Task { @MainActor () throws -> Bool in
            defer { pending = nil }
            let persisted = try await bootstrap.resolve(persisted: true)
            guard persisted.name == name, persisted.bundleId == selected.bundleId,
                  persisted.authNamespace == namespace, persisted.mutable else {
                throw DaemonError.launchFailed("The persisted Cloud environment changed before apply.")
            }
            guard persisted.authNamespace != selected.authNamespace else { return false }
            await signOut()
            stopServices()
            _ = try await bootstrap.startRelaunch()
            // The next Rust `server ensure` also hands off an owner from another
            // backend. A failed shutdown must not strand the signed-out app.
            try? await stopDaemon()
            return true
        }
        pending = task
        return task
    }
}
