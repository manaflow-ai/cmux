import CmuxTerminalBackendService
import Foundation

/// Reports the app-bundled terminal service's registration state before AppKit starts.
struct TerminalBackendServiceStatusCommand {
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

        let registration = SystemBackendServiceRegistration(
            propertyListName: descriptor.propertyListName
        )
        let value = switch await registration.status() {
        case .notRegistered:
            "not-registered"
        case .enabled:
            "enabled"
        case .requiresApproval:
            "requires-approval"
        case .notFound:
            "not-found"
        }
        FileHandle.standardOutput.write(Data("\(value)\n".utf8))
        return 0
    }

    private func writeError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
