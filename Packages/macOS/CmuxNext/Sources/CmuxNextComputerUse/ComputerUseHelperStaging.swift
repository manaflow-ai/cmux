// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxNextAgentActivity
import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation
import os
import Security

/// Copies a signed cmux Computer Use helper out of this app's bundle and
/// returns the copy to launch.
///
/// macOS 26 checks Screen Recording for a helper that runs from inside an app
/// bundle as the outermost app (cmux NIGHTLY), not as the helper. Accessibility
/// still uses the helper's own identity. So a nested helper gets Accessibility
/// but never Screen Recording, even with its own "cmux Computer Use" switch on.
/// A copy outside any app is checked as itself (com.cmuxterm.cua), the same as
/// classic cmux's copy, so the person's existing grant applies.
///
/// The copy lives at a stable path per app build (scope), so Settings keeps one
/// row. It is reused while it matches the source (CFBundleVersion and code
/// directory hash), and replaced atomically when the source changes: copied to
/// a private temporary folder, checked, then swapped in. A copy that cannot be
/// made or verified is never launched. Paths are never followed through a
/// symlink: the folders must be this user's own real directories.
nonisolated struct ComputerUseHelperStaging: Sendable {
    /// What decides that a copy is the same helper as its source.
    struct Stamp: Equatable, Sendable {
        var version: String
        var codeDirectoryHash: Data
    }

    typealias RunningCheck = @Sendable (pid_t) -> Bool

    /// The file and signature work (the real ones by default, fakes in tests).
    struct Operations: Sendable {
        /// Copies the bundle at `source` to the new path `destination` without quarantine.
        var copy: @Sendable (_ source: URL, _ destination: URL) async -> Bool
        /// The bundle's version and code directory hash; nil when unsigned or unreadable.
        var stamp: @Sendable (URL) -> Stamp?
        /// Whether `copy` passes the signature check that `source` passed.
        var verify: @Sendable (_ copy: URL, _ source: URL) -> Bool

        /// Captures the requirement before launch, then checks the live pid.
        var makeRunningCheck: @Sendable (URL) -> RunningCheck?

        static func system(verify: @escaping @Sendable (_ copy: URL, _ source: URL) -> Bool,
                           requirement: @escaping @Sendable (URL) -> SecRequirement?) -> Operations {
            Operations(copy: { await ComputerUseHelperStaging.ditto($0, $1) },
                       stamp: { ComputerUseHelperStaging.readStamp($0) },
                       verify: verify, makeRunningCheck: { source in
                guard let requirement = requirement(source), let data = ComputerUseHelperStaging.requirementData(requirement) else { return nil }
                return { pid in ComputerUseHelperStaging.satisfiesRunningRequirement(pid, data: data) }
            })
        }
    }

    /// Filesystem seams for rename races, path checks and cleanup.
    struct FileSystem: Sendable {
        struct Entry: Sendable {
            var owner: uid_t
            var mode: mode_t
            var modified: Date

            static func read(_ url: URL) -> Entry? {
                var info = stat()
                guard lstat(url.path, &info) == 0 else { return nil }
                return Entry(owner: info.st_uid, mode: info.st_mode,
                             modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                                            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000))
            }
        }

        var move: @Sendable (URL, URL, UInt32) -> Int32 = { source, destination, flags in
            renamex_np(source.path, destination.path, flags) == 0 ? 0 : errno
        }
        var now: @Sendable () -> Date = { Date() }
        var inspect: @Sendable (URL) -> Entry? = { Entry.read($0) }
        var resolve: @Sendable (URL) -> String? = { url in
            // Foundation rewrites /private aliases. Compare the POSIX real path.
            guard let path = realpath(url.path, nil) else { return nil }
            defer { free(path) }
            return String(cString: path)
        }
    }

    /// The private folder that holds the copy (one per app build).
    let folder: URL
    let operations: Operations
    let home: URL
    let fileSystem: FileSystem

    init(folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         operations: Operations, fileSystem: FileSystem = .init()) {
        self.folder = folder
        self.operations = operations
        self.home = home
        self.fileSystem = fileSystem
    }

    /// The legacy helper's copy: `.../cmux-cua/helper/next-<scope>/cmux Computer Use.app`,
    /// checked against the release helper's Developer ID requirement.
    static func legacy(bundleID: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ComputerUseHelperStaging {
        let operations = Operations.system(verify: { copy, _ in CuaHelperIdentity.satisfiesRequirement(copy) },
                                           requirement: { _ in
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(CuaHelperIdentity.requirement as CFString, [], &requirement) == errSecSuccess else { return nil }
            return requirement
        })
        return ComputerUseHelperStaging(folder: root(home: home).appending(path: "next-\(ComputerUseHelperDaemon.scope(bundleID))",
                                                                          directoryHint: .isDirectory),
                                        home: home, operations: operations)
    }

    /// The helper v2's copy: `.../cmux-cua/helper/next-v2-<scope>/<its name>`, checked
    /// against the source's own designated requirement.
    static func upstream(bundleID: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ComputerUseHelperStaging {
        let operations = Operations.system(verify: { copy, source in satisfiesDesignatedRequirement(copy, of: source) },
                                           requirement: { designatedRequirement(of: $0) })
        return ComputerUseHelperStaging(folder: root(home: home).appending(path: "next-v2-\(ComputerUseHelperDaemon.scope(bundleID))",
                                                                          directoryHint: .isDirectory),
                                        home: home, operations: operations)
    }

    /// `<cmux-cua root>/helper`, where classic cmux keeps its copies too.
    /// The `next-` names keep the classic installer away from these.
    static func root(home: URL) -> URL {
        ComputerUseHelperDaemon.cuaRoot(home: home).appending(path: "helper", directoryHint: .isDirectory)
    }

    /// Where the copy of `source` goes.
    func destination(for source: URL) -> URL {
        folder.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
    }

    /// The copy of the helper named `appName` when it is in place and passes
    /// its signature check (for the setup's "drag this app" tile), else nil.
    @concurrent func existingCopy(named appName: String) async -> URL? {
        let copy = folder.appending(path: appName, directoryHint: .isDirectory)
        guard trustedFolder(create: false), Self.isRealDirectory(copy.path), operations.stamp(copy) != nil, operations.verify(copy, copy) else { return nil }
        return copy
    }

    /// The copy of `source` to launch: the existing one when it matches, else
    /// a fresh verified copy. Nil when the copy cannot be made or verified.
    @concurrent func stage(_ source: URL) async -> URL? {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use")
        guard trustedFolder(create: true, logger: logger) else {
            logger.error("cmux Computer Use helper copy: \(folder.path, privacy: .public) is not a private directory of this user")
            return nil
        }
        sweepStaleFolders()
        guard let wanted = operations.stamp(source) else {
            logger.error("cmux Computer Use helper copy: cannot read the signature of \(source.path, privacy: .public)")
            return nil
        }
        let destination = destination(for: source)
        if Self.isRealDirectory(destination.path), operations.stamp(destination) == wanted, operations.verify(destination, source) {
            return destination
        }
        let staging = folder.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard mkdir(staging.path, 0o700) == 0 else { return nil }
        defer { try? FileManager.checked.removeItem(at: staging) }
        let copy = staging.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
        guard await operations.copy(source, copy) else {
            logger.error("cmux Computer Use helper copy: copying \(source.path, privacy: .public) failed")
            return nil
        }
        guard trustedFolder(create: false) else { return nil }
        _ = removexattr(copy.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard Self.isRealDirectory(copy.path), operations.stamp(copy) == wanted, operations.verify(copy, source) else {
            logger.error("cmux Computer Use helper copy: the copy of \(source.path, privacy: .public) did not pass its signature check")
            return nil
        }
        // Swap the new copy in, so a launch never sees a half-written helper;
        // the old copy then sits in the staging folder, which the defer removes.
        // Anything else in the way (a symlink, a file) is unlinked, never followed.
        var existing = stat()
        var flags = RENAME_EXCL
        if lstat(destination.path, &existing) == 0 {
            if existing.st_mode & S_IFMT == S_IFDIR {
                flags = RENAME_SWAP
            } else {
                guard unlink(destination.path) == 0 else { return nil }
            }
        }
        let failure = fileSystem.move(copy, destination, UInt32(flags))
        guard failure == 0 else {
            if failure == EEXIST, trustedFolder(create: false), Self.isRealDirectory(destination.path),
               operations.stamp(destination) == wanted, operations.verify(destination, source) {
                return destination
            }
            logger.error("cmux Computer Use helper copy: cannot move the copy to \(destination.path, privacy: .public) (errno \(failure, privacy: .public))")
            return nil
        }
        guard trustedFolder(create: false), Self.isRealDirectory(destination.path) else { return nil }
        logger.notice("cmux Computer Use helper copied to \(destination.path, privacy: .public)")
        return destination
    }

    /// Captures the trusted source requirement before staging or launch can race it.
    @concurrent func runningCheck(for source: URL) async -> RunningCheck? {
        operations.makeRunningCheck(source)
    }

    /// Checks the process before its tokens or control pipe can be used.
    @concurrent func acceptsRunningProcess(_ pid: pid_t, check: RunningCheck) async -> Bool {
        check(pid)
    }

    /// Checks each parent before creating a child. Existing modes are never
    /// repaired: a folder with group write (umask 002 makes 0775) is refused
    /// too, since the group is `staff`, which holds every local user, so
    /// another user could swap the copy. `logger` names the folder that failed.
    private func trustedFolder(create: Bool, logger: Logger? = nil) -> Bool {
        let expected = folder.absoluteURL
        let home = home.absoluteURL
        guard !expected.pathComponents.contains("."), !expected.pathComponents.contains(".."),
              expected.path.hasPrefix(Self.root(home: home).path + "/"),
              fileSystem.resolve(home) == home.path else { return false }
        var directory = home
        for component in expected.pathComponents.dropFirst(home.pathComponents.count) {
            directory.append(path: component, directoryHint: .isDirectory)
            if create, mkdir(directory.path, 0o700) != 0, errno != EEXIST { return false }
            guard let info = fileSystem.inspect(directory), info.mode & S_IFMT == S_IFDIR,
                  info.owner == geteuid(), info.mode & 0o022 == 0 else {
                let found = fileSystem.inspect(directory).map { "owner \($0.owner), mode \(String($0.mode, radix: 8))" } ?? "missing"
                logger?.error("cmux Computer Use helper copy: \(directory.path, privacy: .public) must be a real directory of this user without group or world write (\(found, privacy: .public))")
                return false
            }
        }
        return fileSystem.resolve(expected) == expected.path
    }

    /// Removes only this user's real staging directories older than five minutes.
    private func sweepStaleFolders() {
        let cutoff = fileSystem.now().addingTimeInterval(-300)
        guard let entries = try? FileManager.checked.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".staging-") {
            guard let info = fileSystem.inspect(entry), info.mode & S_IFMT == S_IFDIR,
                  info.owner == geteuid(), info.modified < cutoff else { continue }
            try? FileManager.checked.removeItem(at: entry)
        }
    }

    /// A directory owned by this user, not a symlink.
    static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == geteuid()
    }

    // MARK: The system operations

    /// `/usr/bin/ditto --noqtn`: a bundle copy that keeps the signature and drops quarantine.
    static func ditto(_ source: URL, _ destination: URL) async -> Bool {
        let request = ProcessRequest(URL(fileURLWithPath: "/usr/bin/ditto"), ["--noqtn", source.path, destination.path],
                                     environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(60))
        guard let outcome = try? await AsyncProcess().run(request) else { return false }
        return outcome.succeeded
    }

    static func readStamp(_ bundle: URL) -> Stamp? {
        guard let data = try? Data(blockingContentsOf: bundle.appending(path: "Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let version = plist["CFBundleVersion"] as? String,
              let hash = ComputerUseHelperV2.cdhash(bundle) else { return nil }
        return Stamp(version: version, codeDirectoryHash: hash)
    }

    private static func designatedRequirement(of source: URL) -> SecRequirement? {
        var sourceCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(source as CFURL, [], &sourceCode) == errSecSuccess, let sourceCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(sourceCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// Data keeps the captured requirement immutable and safe to send between actors.
    private static func requirementData(_ requirement: SecRequirement) -> Data? {
        var data: CFData?
        guard SecRequirementCopyData(requirement, [], &data) == errSecSuccess, let data else { return nil }
        return data as Data
    }

    /// Checks the live code against the captured requirement, without reading the source path.
    private static func satisfiesRunningRequirement(_ pid: pid_t, data: Data) -> Bool {
        guard pid > 0 else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithData(data as CFData, [], &requirement) == errSecSuccess, let requirement else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    /// Whether `copy` is validly signed (strict, all architectures, nested code)
    /// and satisfies the designated requirement of `source`.
    static func satisfiesDesignatedRequirement(_ copy: URL, of source: URL) -> Bool {
        guard let requirement = designatedRequirement(of: source) else { return false }
        var copyCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(copy as CFURL, [], &copyCode) == errSecSuccess, let copyCode else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        // concurrency-allow: only the `upstream` verify operation calls it, and only the @concurrent existingCopy(named:) and stage(_:) run that, never main
        return SecStaticCodeCheckValidity(copyCode, flags, requirement) == errSecSuccess
    }
}
