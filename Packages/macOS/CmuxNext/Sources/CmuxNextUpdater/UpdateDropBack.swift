import AppKit
public import Foundation
import Security

/// Drop back to a previous build: the one path every entrypoint takes (palette and app menu
/// "Roll Back to Previous Version…", `cmux settings rollback-update --confirm`,
/// `app call updates.rollback`, and offers such as the pulled-build banner). Its own type, not an
/// `UpdaterService` extension, so the updater does not grow.
@MainActor
public enum UpdateDropBack {
    /// Rolls back to `build` (nil: the newest kept build). With `checkOnly` it only answers
    /// whether the rollback would run. A refusal throws ``RollbackRefusal`` (its `message` is
    /// what the user reads); otherwise the bundles swap, the build left behind is no longer
    /// offered, and the app relaunches into the kept build with every session kept.
    @discardableResult
    public static func run(_ updater: UpdaterService, to build: String? = nil, checkOnly: Bool = false,
                           stateDirectories: [URL?]) async throws -> KeptVersion {
        let inputs = await updater.rollbackInputs(stateDirectories: stateDirectories)
        if checkOnly { return try updater.rollbackDecision(to: build, inputs: inputs).get() }
        return try updater.rollback(to: build, inputs: inputs, relaunch: relaunchAfterExit)
    }

    /// ``run(_:to:checkOnly:stateDirectories:)`` for an action: nil when it ran, else what the
    /// user reads (a refusal's message, or the swap's error).
    public static func failure(_ updater: UpdaterService, to build: String?, stateDirectories: [URL?]) async -> String? {
        do {
            try await run(updater, to: build, stateDirectories: stateDirectories)
            return nil
        } catch let refusal as RollbackRefusal {
            return refusal.message
        } catch {
            return String(describing: error)
        }
    }

    /// Starts the helper that reopens `app` once this process exits, then quits (the relaunch
    /// hook already recorded "keep sessions").
    public static func relaunchAfterExit(_ app: URL) {
        let command = RollbackSwap.relaunchCommand(pid: ProcessInfo.processInfo.processIdentifier, app: app)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: command[0])
        helper.arguments = Array(command.dropFirst())
        do { try helper.run() } catch { return }
        RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
    }

    /// The Developer ID team of a valid signed bundle, else nil.
    nonisolated static func signingTeam(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
