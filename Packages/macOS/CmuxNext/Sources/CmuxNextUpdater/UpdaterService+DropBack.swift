import AppKit
public import Foundation

extension UpdaterService {
    /// Starts the helper that reopens `app` once this process exits, then
    /// quits (the relaunch hook already recorded "keep sessions").
    public static func relaunchAfterExit(_ app: URL) {
        let command = RollbackSwap.relaunchCommand(pid: ProcessInfo.processInfo.processIdentifier, app: app)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: command[0])
        helper.arguments = Array(command.dropFirst())
        do { try helper.run() } catch { return }
        RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
    }
}

extension UpdaterService {
    /// Drop back to a previous build: the one path every entrypoint takes (palette and app menu
    /// "Roll Back to Previous Version…", `cmux settings rollback-update --confirm`,
    /// `app call updates.rollback`, and any later offer such as the server pulling a bad
    /// nightly). `build` nil picks the newest kept build. With `checkOnly` it only answers
    /// whether the rollback would run. A refusal throws ``RollbackRefusal`` (its `message` is
    /// what the user reads); otherwise the bundles swap, the build left behind is no longer
    /// offered, and the app relaunches into the kept build with every session kept.
    @discardableResult
    public func dropBack(to build: String? = nil, checkOnly: Bool = false, stateDirectories: [URL?]) async throws -> KeptVersion {
        let inputs = await rollbackInputs(stateDirectories: stateDirectories)
        if checkOnly { return try rollbackDecision(to: build, inputs: inputs).get() }
        return try rollback(to: build, inputs: inputs, relaunch: Self.relaunchAfterExit)
    }

    /// ``dropBack(to:checkOnly:stateDirectories:)`` for an action: nil when it ran, else what
    /// the user reads (a refusal's message, or the swap's error).
    public func dropBackFailure(to build: String?, stateDirectories: [URL?]) async -> String? {
        do {
            try await dropBack(to: build, stateDirectories: stateDirectories)
            return nil
        } catch let refusal as RollbackRefusal {
            return refusal.message
        } catch {
            return String(describing: error)
        }
    }
}
