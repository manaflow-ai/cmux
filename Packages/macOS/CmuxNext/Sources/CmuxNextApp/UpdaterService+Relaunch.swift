import AppKit
import CmuxNextUpdater
import Foundation

extension UpdaterService {
    /// Starts the helper that reopens `app` once this process exits, then
    /// quits (the relaunch hook already recorded "keep sessions").
    static func relaunchAfterExit(_ app: URL) {
        let command = RollbackSwap.relaunchCommand(pid: ProcessInfo.processInfo.processIdentifier, app: app)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: command[0])
        helper.arguments = Array(command.dropFirst())
        do { try helper.run() } catch { return }
        RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
    }
}
