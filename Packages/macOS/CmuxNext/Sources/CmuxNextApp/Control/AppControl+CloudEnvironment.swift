import CmuxNextCloud
import CmuxNextControl
import Darwin
import Foundation
import os

extension AppControl {
    /// The CLI has persisted Rust's validated selection; this only tears down native resources and relaunches.
    func registerCloudEnvironmentMethods(_ services: AppServices) {
        service?.router.register([
            .mainActor("cloud.environment.apply") { call in
                guard let selected = services.cloud.configuration.runtimeSelection, selected.mutable,
                      call.params["bundle_id"]?.stringValue == Bundle.main.bundleIdentifier,
                      call.params["bundle_id"]?.stringValue == selected.bundleId,
                      let name = call.params["name"]?.stringValue,
                      let namespace = call.params["auth_namespace"]?.stringValue else {
                    throw ControlError.invalidParams("The Cloud environment does not belong to this mutable app bundle.")
                }
                guard services.cloudEnvironmentApply == nil else {
                    throw ControlError(code: "busy", message: "A Cloud environment change is already in progress.")
                }
                let task = Task { @MainActor () throws -> Bool in
                    defer { services.cloudEnvironmentApply = nil }
                    var relaunchPID: Int32?
                    do {
                        let persisted = try await CloudEnvironmentBootstrap(work: services.work).resolve()
                        guard persisted.name == name, persisted.bundleId == selected.bundleId,
                              persisted.authNamespace == namespace, persisted.mutable else {
                            throw ControlError.invalidParams("The persisted Cloud environment changed before apply.")
                        }
                        guard persisted.name != selected.name || persisted.authNamespace != selected.authNamespace else {
                            return false
                        }
                        await services.cloud.signOut()
                        services.cloud.stop()
                        services.feed.stop()
                        services.iphone.stop()
                        // Start the helper after network sign-out; it waits for this process's exit.
                        relaunchPID = try await CloudEnvironmentBootstrap(work: services.work).startRelaunch()
                        try await services.daemon.stopKeepingHosts()
                        services.quit.requestQuit(.signal)
                        return true
                    } catch {
                        if let relaunchPID { kill(relaunchPID, SIGTERM) }
                        Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")
                            .error("Cloud environment apply failed: \(String(describing: error), privacy: .public)")
                        throw error
                    }
                }
                services.cloudEnvironmentApply = task
                return .followUp { [task] in
                    let scheduled = try await task.value
                    return .object(["restart_scheduled": .bool(scheduled), "name": .string(name)])
                }
            // timeout: remote sign-out/revocation may hang; report a saved selection that needs restart.
            }.withDeadline(.fixed(.seconds(120))),
        ])
    }
}
