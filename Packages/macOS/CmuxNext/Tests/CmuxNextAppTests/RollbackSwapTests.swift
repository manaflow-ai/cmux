import CryptoKit
import Foundation
@testable import CmuxNextUpdater
import Testing

/// Drop back to the previous build: the swap puts the kept build in place and keeps the running
/// one, and a swap that fails part way must leave the kept build in the store (it is the only
/// build the user can drop back to).
@Suite(.serialized) struct RollbackSwapTests {
    private static func makeBundle(at url: URL, build: String) throws {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleVersion": build, "CFBundleShortVersionString": "1.0.\(build)"]
        try info.write(to: contents.appending(path: "Info.plist"))
    }

    private static func build(of bundle: URL) -> String? {
        (NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")) as? [String: Any])?["CFBundleVersion"] as? String
    }

    private static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "RollbackSwapTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func swapPutsTheKeptBuildInPlaceAndKeepsTheRunningOne() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KeptVersionStore(root: root.appending(path: "versions"), teamID: { _ in "TEAM" })
        let app = root.appending(path: "Applications/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: app, build: "200")
        let previous = root.appending(path: "previous/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: previous, build: "100")
        try store.keep(bundle: previous, build: "100", limit: 2)
        let target = try #require(store.list().first)

        try RollbackSwap.perform(current: app, currentBuild: "200", target: target, store: store, limit: 1)

        #expect(Self.build(of: app) == "100")
        #expect(store.list().map(\.build) == ["200"])
    }

    /// cmux#41013 review F3: a rollback's quit refused at a quit dialog leaves cmux running, so the
    /// running build goes back in place and the kept build back to the store, with its record.
    @Test func aRefusedQuitPutsTheRunningBuildBack() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = KeptVersionStore(root: root.appending(path: "versions"), teamID: { _ in "TEAM" }, recordKey: { key })
        let app = root.appending(path: "Applications/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: app, build: "200")
        let previous = root.appending(path: "previous/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: previous, build: "100")
        try store.keep(bundle: previous, build: "100", limit: 2, record: KeptRecord(build: "100", date: "2026-11-10", storeSchemas: ["chats": 3]))
        let target = try #require(store.list().first)
        let record = KeptRecord.read(from: target.bundle.deletingLastPathComponent().appending(path: KeptVersionStore.recordName))

        try RollbackSwap.perform(current: app, currentBuild: "200", target: target, store: store, limit: 2)
        #expect(Self.build(of: app) == "100")
        try RollbackSwap.undo(current: app, runningBuild: "200", target: target, targetRecord: record, store: store)

        #expect(Self.build(of: app) == "200")
        let kept = store.list(teams: false)
        #expect(kept.map(\.build) == ["100"])
        #expect(kept.first?.storeSchemas == ["chats": 3] && kept.first?.date == "2026-11-10")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path)
        #expect(leftovers == ["cmux.app"], "nothing staged is left beside the app")
        // The seal is taken again (the moves changed every ctime): going back again is not refused as changed.
        let again = try #require(kept.first)
        #expect(store.stillSealed(again), "a retry after a cancelled rollback is not refused (cmux#41013 review)")
        try RollbackSwap.perform(current: app, currentBuild: "200", target: again, store: store, limit: 2)
        #expect(Self.build(of: app) == "100")
    }

    @Test func aFailedSwapLeavesTheKeptBuildInTheStore() throws {
        let root = try Self.scratch()
        let versions = root.appending(path: "versions", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: versions.path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = KeptVersionStore(root: versions, teamID: { _ in "TEAM" })
        let app = root.appending(path: "Applications/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: app, build: "200")
        let previous = root.appending(path: "previous/cmux.app", directoryHint: .isDirectory)
        try Self.makeBundle(at: previous, build: "100")
        try store.keep(bundle: previous, build: "100", limit: 2)
        let target = try #require(store.list().first)
        // The store's root refuses new folders, so keeping the running build fails mid-swap.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: versions.path)

        #expect(throws: (any Error).self) {
            try RollbackSwap.perform(current: app, currentBuild: "200", target: target, store: store, limit: 1)
        }

        #expect(Self.build(of: app) == "200")
        #expect(Self.build(of: target.bundle) == "100")
        #expect(store.list().map(\.build) == ["100"])
    }

    /// cmux#32624's proof on a fleet Mac: the swap failed with NSCocoaError 512 whose underlying
    /// error was POSIX EINTR. An interrupted call is tried again; any other failure is not.
    @Test func anInterruptedSwapIsTriedAgainAndOtherFailuresAreNot() throws {
        let interrupted = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EINTR)),
            ]),
        ])
        var calls = 0
        try RollbackSwap.retryingInterrupted {
            calls += 1
            if calls < 3 { throw interrupted }
        }
        #expect(calls == 3)

        calls = 0
        #expect(throws: (any Error).self) {
            try RollbackSwap.retryingInterrupted { calls += 1; throw interrupted }
        }
        #expect(calls == 4)

        calls = 0
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        #expect(throws: (any Error).self) {
            try RollbackSwap.retryingInterrupted { calls += 1; throw denied }
        }
        #expect(calls == 1)
    }

    /// The reopen after a rollback keeps a custom home (the weekly rollback drill runs the app in a
    /// throwaway home): `open` gets `--env` for it, and a launch in the account's own home gets the
    /// `open` argv it always had. The helper runs with `printf` in place of `open`, so this reads
    /// the argv `open` would get, a home with a space and a quote included.
    @Test func theReopenKeepsACustomHomeAndOnlyThen() throws {
        let app = URL(fileURLWithPath: "/Applications/cmux NEXT.app")
        let account = "/Users/ci"
        let ownHome = RelaunchHome.openArguments(environment: ["HOME": account], accountHome: account)
        #expect(ownHome.isEmpty)
        let own = RollbackSwap.relaunchCommand(pid: 42, app: app, openOptions: ownHome)
        #expect(own == ["/bin/sh", "-c", #"/usr/bin/caffeinate -w 42; /usr/bin/open "$@" "$0""#, app.path])
        #expect(try Self.openArgv(own) == ["/usr/bin/open", app.path])

        let drill = "/private/tmp/walk home/it's \(UUID().uuidString)"
        let options = RelaunchHome.openArguments(environment: ["HOME": drill, "CFFIXED_USER_HOME": drill], accountHome: account)
        #expect(options == ["--env", "HOME=\(drill)", "--env", "CFFIXED_USER_HOME=\(drill)"])
        let custom = RollbackSwap.relaunchCommand(pid: 42, app: app, openOptions: options)
        #expect(custom[2] == own[2], "the home is an argument, never script text")
        #expect(try Self.openArgv(custom) == ["/usr/bin/open", "--env", "HOME=\(drill)", "--env", "CFFIXED_USER_HOME=\(drill)", app.path])
    }

    @Test func relaunchHomePassesOnlyTheVariablesThatAreSet() {
        let account = "/Users/ci"
        #expect(RelaunchHome.openArguments(environment: [:], accountHome: account).isEmpty)
        #expect(RelaunchHome.openArguments(environment: ["HOME": "/tmp/h"], accountHome: account) == ["--env", "HOME=/tmp/h"])
        #expect(RelaunchHome.openArguments(environment: ["HOME": account, "CFFIXED_USER_HOME": "/tmp/h"], accountHome: account)
            == ["--env", "HOME=\(account)", "--env", "CFFIXED_USER_HOME=/tmp/h"])
        #expect(RelaunchHome.openArguments(environment: ["CFFIXED_USER_HOME": "/tmp/h"], accountHome: account)
            == ["--env", "CFFIXED_USER_HOME=/tmp/h"])
    }

    /// Both reopens rest on macOS's own `open --env`, so a change there would quietly bring the
    /// app back in the account's home: `open`'s usage lists the flag.
    @Test func openListsTheEnvOption() throws {
        let usage = try RelaunchHomeShell.run(["/bin/sh", "-c", "/usr/bin/open -h 2>&1; true"]).joined(separator: "\n")
        #expect(usage.contains("--env"), "open usage: \(usage)")
    }

    /// In a login session (where LaunchServices launches apps), an app `open --env` launches gets
    /// the home it was given, a space and a quote included. The app is a throwaway background-only
    /// bundle whose executable writes what it got.
    @Test(.enabled(if: RelaunchHomeShell.inLoginSession, "LaunchServices launches apps only in a login session"))
    func openGivesTheLaunchedAppTheHome() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Home Probe.app", directoryHint: .isDirectory)
        let executable = app.appending(path: "Contents/MacOS/probe")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleExecutable": "probe", "CFBundlePackageType": "APPL", "LSBackgroundOnly": true,
                                  "CFBundleIdentifier": "com.cmuxterm.test.relaunch-home.\(UUID().uuidString)"]
        try info.write(to: app.appending(path: "Contents/Info.plist"))
        try #"""
        #!/bin/sh
        printf '%s|%s|%s\n' "$HOME" "${CFFIXED_USER_HOME-unset}" "${RELAUNCH_HOME_CALLER-unset}" > "$1"
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let drill = root.appending(path: "walk home/it's").path
        let out = root.appending(path: "seen")
        let options = RelaunchHome.openArguments(environment: ["HOME": drill, "CFFIXED_USER_HOME": drill], accountHome: "/Users/ci")
        _ = try RelaunchHomeShell.run(["/usr/bin/env", "RELAUNCH_HOME_CALLER=caller", "/usr/bin/open", "-W", "-n", "-g"]
                                      + options + [app.path, "--args", out.path])
        let seen = try String(contentsOf: out, encoding: .utf8)
        print("open --env probe: the launched app saw HOME|CFFIXED_USER_HOME|caller variable = \(seen)")
        #expect(seen.hasPrefix("\(drill)|\(drill)|"), "seen: \(seen)")
    }

    /// Runs the relaunch helper without its wait and with `printf` in place of `/usr/bin/open`;
    /// returns the argv `open` would get, one element per line.
    private static func openArgv(_ command: [String]) throws -> [String] {
        let script = try #require(command[2].components(separatedBy: "; ").last)
            .replacingOccurrences(of: "/usr/bin/open", with: #"/usr/bin/printf '%s\n' /usr/bin/open"#)
        return try RelaunchHomeShell.run([command[0], command[1], script] + command.dropFirst(3))
    }
}

/// Runs a helper's shell command in tests and returns its stdout lines.
nonisolated enum RelaunchHomeShell {
    /// Whether this process runs in a login (Aqua) session, where LaunchServices launches apps.
    static let inLoginSession = ((try? run(["/bin/launchctl", "managername"])) ?? []).first == "Aqua"

    struct Failed: Error {
        let command: [String]
        let status: Int32
    }

    static func run(_ command: [String]) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failed(command: command, status: process.terminationStatus) }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }
}
