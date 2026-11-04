import CmuxNextDaemon
import Darwin
import Foundation

/// Native lifecycle adapter after Rust has persisted a selection.
@MainActor public final class CloudEnvironmentSwitch {
    private var pending: Task<Bool, Error>?

    public init() {}

    public func apply(selected: CloudRuntimeSelection, name: String, namespace: String,
                      bootstrap: CloudEnvironmentBootstrap,
                      signOut: @escaping @MainActor () async -> Void,
                      stopServices: @escaping @MainActor () -> Void,
                      stopDaemon: @escaping @MainActor () async throws -> Void,
                      quit: @escaping @MainActor () -> Void) throws -> Task<Bool, Error> {
        guard pending == nil else { throw DaemonError.launchFailed("A Cloud environment change is already in progress.") }
        let task = Task { @MainActor () throws -> Bool in
            defer { pending = nil }
            let persisted = try await bootstrap.resolve()
            guard persisted.name == name, persisted.bundleId == selected.bundleId,
                  persisted.authNamespace == namespace, persisted.mutable else {
                throw DaemonError.launchFailed("The persisted Cloud environment changed before apply.")
            }
            guard persisted.authNamespace != selected.authNamespace else { return false }
            await signOut()
            stopServices()
            let helper = try await bootstrap.startRelaunch()
            do {
                try await stopDaemon()
                quit()
                return true
            } catch {
                kill(helper, SIGTERM)
                throw error
            }
        }
        pending = task
        return task
    }
}
