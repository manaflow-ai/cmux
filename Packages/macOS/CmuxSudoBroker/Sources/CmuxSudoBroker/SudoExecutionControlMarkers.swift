import Foundation

/// Defines the PTY control records exchanged with the privileged executor.
struct SudoExecutionControlMarkers: Sendable, Equatable {
    let token: String
    let inputReady = Data("__CMUX_SUDO_SCRIPT_READY__".utf8)
    var executionTimedOut: Data { marker("EXECUTION_TIMED_OUT") }
    var cleanupFailed: Data { marker("CLEANUP_FAILED") }
    var transportFailed: Data { marker("TRANSPORT_FAILED") }
    var launchFailed: Data { marker("LAUNCH_FAILED") }

    init(token: String = UUID().uuidString) {
        self.token = token
    }

    static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == 36
            && token.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }
    }

    private func marker(_ name: String) -> Data {
        Data("__CMUX_SUDO_CONTROL_\(token)_\(name)__".utf8)
    }
}
