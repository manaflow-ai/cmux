import AppKit
import CmuxNextCompat
import CmuxNextWakeups
public import Foundation
import Security

/// Drop back to a previous build: the one path every entrypoint takes (the Updated card's Go back,
/// palette and app menu "Go Back to the Previous Build…", `cmux settings rollback-update --confirm`,
/// `app call updates.rollback`, `cmux nightly install previous`, and offers such as the pulled-build
/// banner). Its own type, not an `UpdaterService` extension, so the updater does not grow.
///
/// Leo (2026-11-11): "reverting the app to previous nightly is really slow/doesn't work very well
/// sometimes?". The build this Mac updated from is kept (cloned) when the update stages, with a
/// record of its team and the stores it reads (``KeptRecord``), so going back reads no network and
/// checks no whole bundle at the click: it reads the kept list, asks the running cmux-tui which
/// store formats it holds, swaps the bundles and relaunches once with every session.
@MainActor
public struct UpdateDropBack {
    public let updater: UpdaterService

    public init(_ updater: UpdaterService) {
        self.updater = updater
    }

    /// Rolls back to `build` (nil: the previous build, ``RollbackDecision/previous(kept:running:)``).
    /// With `checkOnly` it only answers whether the rollback would run. A refusal throws
    /// ``RollbackRefusal`` (its `message` is what the user reads); otherwise the bundles swap, the
    /// build left behind is no longer offered, and the app relaunches into the kept build with every
    /// session kept.
    @discardableResult
    public func run(to build: String? = nil, checkOnly: Bool = false, stateDirectories: [URL?]) async throws -> KeptVersion {
        if !checkOnly {
            Self.mark("revert.clicked")
            updater.revert = RevertProgress(step: .checking, target: build)
        }
        do {
            let inputs = await updater.rollbackInputs(stateDirectories: stateDirectories)
            if checkOnly { return try updater.rollbackDecision(to: build, inputs: inputs).get() }
            Self.mark("revert.inputs_read")
            let target = try await updater.swapForRollback(to: build, inputs: inputs)
            try await restart(into: target)
            return target
        } catch {
            if !checkOnly { updater.revert = RevertProgress(step: .failed, target: build, failure: Self.message(error)) }
            throw error
        }
    }

    /// The kept build is in place: one relaunch, with every session. The quit hands the agent
    /// daemon to the build it opens (as Restart to Update does, ``UpdaterService/relaunchesIntoUpdate``)
    /// and takes the windows off the screen at once. A helper that cannot start leaves cmux running
    /// and says how to finish.
    private func restart(into target: KeptVersion) async throws {
        let label = RevertTarget(kept: target).label
        updater.revert = RevertProgress(step: .restarting, target: target.build, label: label)
        guard await Self.relaunchAfterExit(Bundle.main.bundleURL) else {
            updater.log.append("rollback: the relaunch helper did not start; \(target.build) opens on the next launch")
            throw RollbackRefusal.relaunchFailed(target)
        }
        updater.relaunchesIntoUpdate = true
        updater.willRelaunch?()
        updater.hidesForRelaunch?()
        NSApplication.terminateFromRunLoop()
    }

    /// Go back one build, the Updated card's and the menu's action: the kept build this Mac came
    /// from, at once; with none kept (an update from before keeping, or a kept copy removed), the
    /// newest earlier build the feed still offers, downloaded and checked first. Nil when it runs
    /// (the app quits), else what the person reads.
    public func goBack(stateDirectories: [URL?]) async -> String? {
        do {
            try await run(stateDirectories: stateDirectories)
            return nil
        } catch RollbackRefusal.nothingKept, RollbackRefusal.nothingOlder {
            // Nothing kept to go back to: the feed's previous build, through the Switch's download.
            guard let target = await updater.previousOfferedBuild() else {
                let why = UpdaterStrings.rollbackNothingKept
                updater.revert = RevertProgress(step: .failed, failure: why)
                return why
            }
            updater.log.append("go back: nothing kept older than \(updater.identity.build); downloading \(target)")
            return await updater.switchToBuild(target)
        } catch {
            return Self.message(error)
        }
    }

    /// ``run(to:checkOnly:stateDirectories:)`` for an action: nil when it ran, else what the
    /// user reads (a refusal's message, or the swap's error).
    public func failure(to build: String?, stateDirectories: [URL?]) async -> String? {
        if build == nil { return await goBack(stateDirectories: stateDirectories) }
        do {
            try await run(to: build, stateDirectories: stateDirectories)
            return nil
        } catch {
            return Self.message(error)
        }
    }

    static func message(_ error: any Error) -> String {
        (error as? RollbackRefusal)?.message ?? UpdaterStrings.rollbackSwapFailed(String(describing: error))
    }

    /// The question asked before a person's rollback runs: `updates.rollback` is destructive (it
    /// quits and relaunches), so the App's destructive confirmation asks this for the palette and
    /// the menu. It names the build when one is known ("Go Back to nightly 4288034 from Nov 10?").
    public static func confirmation(_ target: RevertTarget?) -> (title: String, body: String, button: String) {
        let title = target.map { UpdaterStrings.goBackConfirmTitle($0.label) } ?? UpdaterStrings.rollbackConfirmTitle
        let body = target?.kept == false ? UpdaterStrings.goBackDownloadBody : UpdaterStrings.rollbackConfirmBody
        return (title, body, UpdaterStrings.goBackButton)
    }

    /// ``confirmation(_:)`` made into the caller's prompt (`Prompt.init(title:body:button:)`).
    public static func confirmation<Prompt>(_ target: RevertTarget?, as make: (String, String, String) -> Prompt) -> Prompt {
        let ask = confirmation(target)
        return make(ask.title, ask.body, ask.button)
    }

    /// The update harness's timeline (DEV harness copies only; a no-op everywhere else).
    nonisolated static func mark(_ name: String) {
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark(name)
        #endif
    }

    /// Starts the helper that reopens `app` once this process exits, then quits (the relaunch
    /// hook already recorded "keep sessions"). False when the helper could not start: nothing
    /// would reopen cmux, so it does not quit.
    public static func relaunchAfterExit(_ app: URL) async -> Bool {
        let command = RollbackSwap.relaunchCommand(pid: ProcessInfo.processInfo.processIdentifier, app: app)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: command[0])
        helper.arguments = Array(command.dropFirst())
        do { try await ProcessLauncher(label: "com.cmuxterm.next.relaunch", priority: .userBlocking).launched(helper) } catch { return false }
        mark("revert.relaunch_helper")
        return true
    }

    /// The Developer ID team of a valid signed bundle, every file checked, else nil (a kept build
    /// with no record, a download).
    nonisolated static func signingTeam(of bundle: URL) -> String? {
        team(of: bundle, flags: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
    }

    /// The team of a kept bundle whose record names it: its executable and Info.plist are checked,
    /// not each resource again (the full check ran when it was kept, and the record's fingerprint
    /// says its signature files have not changed since).
    nonisolated static func quickSigningTeam(of bundle: URL) -> String? {
        team(of: bundle, flags: kSecCSDoNotValidateResources)
    }

    /// The running app's own team: the kernel checked its code when it started, so no file is read
    /// again. Read once.
    nonisolated static let runningTeam: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamIdentifier(staticCode)
    }()

    nonisolated private static func team(of bundle: URL, flags: UInt32) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: flags), nil) == errSecSuccess
        else { return nil }
        return teamIdentifier(code)
    }

    nonisolated private static func teamIdentifier(_ code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return nil }
        let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        #if DEBUG || CMUX_BENCH_HOOKS
        // The update harness signs its copies ad hoc (no team): one name stands for that, so its
        // rollback runs the release path (harness copies only: a DEV bundle on a loopback feed).
        if team == nil, UpdateHarness.current != nil { return UpdateHarness.adHocTeam }
        #endif
        return team
    }
}
