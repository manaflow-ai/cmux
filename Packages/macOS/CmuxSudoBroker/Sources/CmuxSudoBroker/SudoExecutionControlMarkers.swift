import Foundation

/// Defines the PTY control records exchanged with the privileged executor.
struct SudoExecutionControlMarkers: Sendable, Equatable {
    let inputReady = Data("__CMUX_SUDO_SCRIPT_READY__".utf8)
    let executionTimedOut = Data("__CMUX_SUDO_EXECUTION_TIMED_OUT__".utf8)
    let cleanupFailed = Data("__CMUX_SUDO_CLEANUP_FAILED__".utf8)
    let transportFailed = Data("__CMUX_SUDO_TRANSPORT_FAILED__".utf8)
    let launchFailed = Data("__CMUX_SUDO_LAUNCH_FAILED__".utf8)
}
