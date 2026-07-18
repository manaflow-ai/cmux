import CmuxTerminalBackendService
import Darwin
import Foundation

/// Executes the pre-AppKit service teardown path used by tagged-build cleanup.
struct TerminalBackendServiceUnregistrationCommand {
    let bundleURL: URL
    let bundleIdentifier: String?

    func run() async -> Int32 {
        guard let bundleIdentifier,
              let descriptor = BackendServiceDescriptor(bundleIdentifier: bundleIdentifier) else {
            writeError(
                String(
                    localized: "terminalBackend.unregister.invalidBundle",
                    defaultValue: "Unable to identify this app's terminal backend service."
                )
            )
            return 64
        }

        writeError(
            String(
                localized: "terminalBackend.unregister.ptyWarning",
                defaultValue: "Warning: unregistering the terminal backend terminates every PTY it owns."
            )
        )
        let runtimePaths = BackendServiceRuntimePaths(
            descriptor: descriptor,
            userID: UInt32(Darwin.getuid()),
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        let bundleInspection = BackendServiceBundleInspection(
            bundleURL: bundleURL,
            descriptor: descriptor
        )
        let coordinator = BackendServiceBootstrapCoordinator(
            activationPolicy: BackendServiceActivationPolicy(buildSettingValue: "NO"),
            inspection: bundleInspection,
            registration: SystemBackendServiceRegistration(
                descriptor: descriptor,
                bundleInspection: bundleInspection,
                runtimePaths: runtimePaths,
                userID: UInt32(Darwin.getuid())
            ),
            readinessChecker: BackendServiceReadinessProbe(
                descriptor: descriptor,
                runtimePaths: runtimePaths
            )
        )

        do {
            switch try await coordinator.unregister() {
            case .unregistered, .alreadyUnregistered:
                return 0
            case .serviceNotFound:
                writeError(
                    String(
                        localized: "terminalBackend.unregister.serviceNotFound",
                        defaultValue: "The bundled terminal backend service could not be found, so the app was preserved."
                    )
                )
                return 69
            }
        } catch {
            writeError(
                String(
                    localized: "terminalBackend.unregister.failed",
                    defaultValue: "The terminal backend could not be unregistered, so the app was preserved."
                )
            )
            return 70
        }
    }

    private func writeError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
