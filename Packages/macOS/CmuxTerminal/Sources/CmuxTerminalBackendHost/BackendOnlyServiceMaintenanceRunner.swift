public import CmuxTerminalBackendService
internal import Darwin
public import Foundation

/// Runs exact terminal-backend maintenance commands before AppKit starts.
///
/// Tagged-build cleanup uses this path to query or deliberately terminate the
/// persistent daemon without constructing the SwiftUI host or a renderer.
public struct BackendOnlyServiceMaintenanceRunner: Sendable {
    public init() {}

    public func run(
        arguments: [String] = CommandLine.arguments,
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) async -> Int32? {
        guard let invocation = BackendServiceMaintenanceInvocation(arguments: arguments)
        else { return nil }
        guard let bundleIdentifier,
              let descriptor = BackendServiceDescriptor(bundleIdentifier: bundleIdentifier)
        else {
            writeError(BackendOnlyLocalization.string(
                "backendOnly.maintenance.invalidBundle",
                defaultValue: "Unable to identify this app's terminal backend service."
            ))
            return 64
        }

        let userID = UInt32(Darwin.geteuid())
        let runtimePaths = BackendServiceRuntimePaths(
            descriptor: descriptor,
            userID: userID,
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        let inspection = BackendServiceBundleInspection(
            bundleURL: bundleURL,
            descriptor: descriptor
        )
        let registration = SystemBackendServiceRegistration(
            descriptor: descriptor,
            bundleInspection: inspection,
            runtimePaths: runtimePaths,
            userID: userID
        )

        switch invocation.operation {
        case .status:
            do {
                let value = switch try await registration.status() {
                case .notRegistered: "not-registered"
                case .enabled: "enabled"
                case .requiresApproval: "requires-approval"
                case .notFound: "not-found"
                }
                FileHandle.standardOutput.write(Data("\(value)\n".utf8))
                return 0
            } catch {
                return 70
            }
        case .unregister:
            writeError(BackendOnlyLocalization.string(
                "backendOnly.maintenance.ptyWarning",
                defaultValue: "Warning: unregistering the terminal backend terminates every PTY it owns."
            ))
            let coordinator = BackendServiceBootstrapCoordinator(
                activationPolicy: BackendServiceActivationPolicy(buildSettingValue: "NO"),
                inspection: inspection,
                registration: registration,
                readinessChecker: BackendServiceReadinessProbe(
                    descriptor: descriptor,
                    runtimePaths: runtimePaths,
                    expectedUserID: userID
                )
            )
            do {
                switch try await coordinator.unregister() {
                case .unregistered, .alreadyUnregistered:
                    return 0
                case .serviceNotFound:
                    writeError(BackendOnlyLocalization.string(
                        "backendOnly.maintenance.serviceNotFound",
                        defaultValue: "The bundled terminal backend service could not be found, so the app was preserved."
                    ))
                    return 69
                }
            } catch {
                writeError(BackendOnlyLocalization.string(
                    "backendOnly.maintenance.failed",
                    defaultValue: "The terminal backend could not be unregistered, so the app was preserved."
                ))
                return 70
            }
        }
    }

    private func writeError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
