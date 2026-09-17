import Foundation

extension CMUXCLI {
    func ensureCloudFeatureEnabledForPty() throws {
        let environment = ProcessInfo.processInfo.environment
        let socketPath = (try? CLISocketEnvironment.socketPath(in: environment))
            ?? CLISocketPathResolver.defaultSocketPath(
                bundleIdentifier: CLISocketPathResolver.currentAppBundleIdentifier(),
                environment: environment
            )
        let client = SocketClient(path: socketPath)
        do {
            try client.connect()
            defer { client.close() }
            let status = try client.sendV2(method: "vm.feature_status")
            guard status["enabled"] as? Bool == true else {
                throw CLIError(message: String(
                    localized: "cloud.feature.disabled",
                    defaultValue: "Cloud Machines are temporarily unavailable."
                ))
            }
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError(message: String(
                localized: "cloud.feature.disabled",
                defaultValue: "Cloud Machines are temporarily unavailable."
            ))
        }
    }
}
