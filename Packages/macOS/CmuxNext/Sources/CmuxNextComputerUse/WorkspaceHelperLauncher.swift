import AppKit
import Darwin
import CmuxNextAgentActivity
import Foundation
import os

/// LaunchServices gives the helper its own privacy identity.
@MainActor
final class WorkspaceHelperLauncher: ComputerUseHelperLaunching {
    private var scope: ComputerUseHelperScope?

    func launch(_ app: URL, arguments: [String], environment: [String: String]) async -> pid_t? {
        guard let index = arguments.firstIndex(of: "--socket"), arguments.indices.contains(index + 1),
              let directory = environment["CMUX_CUA_STATE_DIR"] else { return nil }
        let socket = arguments[index + 1]
        if scope == nil {
            scope = await ComputerUseHelperScope.acquire(socketPath: socket, stateDirectory: URL(fileURLWithPath: directory))
        }
        guard let scope, scope.socketPath == socket,
              await scope.prepareForLaunch(stateDirectory: URL(fileURLWithPath: directory)) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // Each scope has its own socket and credentials. Reuse happens before this call.
        configuration.createsNewApplicationInstance = true
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        configuration.arguments = arguments
        configuration.environment = environment
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { running, error in
                if let error {
                    Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use")
                        .error("cmux Computer Use helper did not start: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: running?.processIdentifier)
            }
        }
    }

    func terminate(_ pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    func isRunning(_ pid: pid_t) -> Bool {
        // EPERM: it exists under another user. launchd reaps the helper, so a gone pid is ESRCH.
        kill(pid, 0) == 0 || errno == EPERM
    }

    func watchExit(of pid: pid_t, onExit: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        ComputerUseHelperExitWatch.watch(pid, onExit: onExit)
    }
}
