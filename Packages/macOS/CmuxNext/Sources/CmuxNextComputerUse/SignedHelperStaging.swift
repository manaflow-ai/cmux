// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation
import os
import Security

/// Copies a signed helper app out of this app's bundle and returns the copy to launch
/// (``SignedHelperLaunch``; the Screen Sharing helper, plans/cmux-next/screen-sharing-helper.md).
///
/// macOS 26 checks Screen Recording for a helper that runs from inside an app bundle as the
/// outermost app, not as the helper. A copy outside any app is checked as itself.
///
/// The copy lives at a stable path per app build (scope), so Settings keeps one row. It is reused
/// while it matches the source (CFBundleVersion and code directory hash), and replaced atomically
/// when the source changes: copied to a private temporary folder, checked, then swapped in. A copy
/// that cannot be made or verified is never launched. Paths are never followed through a symlink:
/// the folders must be this user's own real directories.
nonisolated struct SignedHelperStaging: Sendable {
    /// What decides that a copy is the same helper as its source.
    struct Stamp: Equatable, Sendable {
        var version: String
        var codeDirectoryHash: Data
    }

    /// The file and signature work (the real ones by default, fakes in tests).
    struct Operations: Sendable {
        /// Copies the bundle at `source` to the new path `destination` without quarantine.
        var copy: @Sendable (_ source: URL, _ destination: URL) async -> Bool
        /// The bundle's version and code directory hash; nil when unsigned or unreadable.
        var stamp: @Sendable (URL) -> Stamp?
        /// Whether `copy` passes the signature check that `source` passed.
        var verify: @Sendable (_ copy: URL, _ source: URL) -> Bool

        /// Copies with ditto, and checks a copy against its source's own designated requirement.
        static let system = Operations(copy: { await SignedHelperStaging.ditto($0, $1) },
                                       stamp: { SignedHelperStaging.readStamp($0) },
                                       verify: { copy, source in SignedHelperStaging.satisfiesDesignatedRequirement(copy, of: source) })
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
    /// The folder every copy of this kind lives under (`folder` must be inside it).
    let root: URL

    init(folder: URL, home: URL, root: URL, operations: Operations = .system, fileSystem: FileSystem = .init()) {
        self.folder = folder
        self.operations = operations
        self.home = home
        self.fileSystem = fileSystem
        self.root = root
    }

    /// The Screen Sharing helper's copy (plans/cmux-next/screen-sharing-helper.md):
    /// `~/Library/Application Support/cmux-next/screen-sharing/<scope>/<its name>` (NEXT's own
    /// folder, ``NextSupport``), checked against the source's own designated requirement.
    static func screenSharing(bundleID: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SignedHelperStaging {
        let support = NextSupport(applicationSupport: home.appending(path: "Library/Application Support", directoryHint: .isDirectory))
        let root = support.folder.appending(path: "screen-sharing", directoryHint: .isDirectory)
        return SignedHelperStaging(folder: root.appending(path: NextSupport.computerUseScope(bundleID), directoryHint: .isDirectory),
                                   home: home, root: root)
    }

    /// Where the copy of `source` goes.
    func destination(for source: URL) -> URL {
        folder.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
    }

    /// The copy of `source` to launch: the existing one when it matches, else
    /// a fresh verified copy. Nil when the copy cannot be made or verified.
    @concurrent func stage(_ source: URL) async -> URL? {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "signed-helper")
        guard trustedFolder(create: true, logger: logger) else {
            logger.error("helper copy: \(folder.path, privacy: .public) is not a private directory of this user")
            return nil
        }
        sweepStaleFolders()
        guard let wanted = operations.stamp(source) else {
            logger.error("helper copy: cannot read the signature of \(source.path, privacy: .public)")
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
            logger.error("helper copy: copying \(source.path, privacy: .public) failed")
            return nil
        }
        guard trustedFolder(create: false) else { return nil }
        _ = removexattr(copy.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard Self.isRealDirectory(copy.path), operations.stamp(copy) == wanted, operations.verify(copy, source) else {
            logger.error("helper copy: the copy of \(source.path, privacy: .public) did not pass its signature check")
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
            logger.error("helper copy: cannot move the copy to \(destination.path, privacy: .public) (errno \(failure, privacy: .public))")
            return nil
        }
        guard trustedFolder(create: false), Self.isRealDirectory(destination.path) else { return nil }
        logger.notice("helper copied to \(destination.path, privacy: .public)")
        return destination
    }

    /// Checks each parent before creating a child. Existing modes are never
    /// repaired: a folder with group write (umask 002 makes 0775) is refused
    /// too, since the group is `staff`, which holds every local user, so
    /// another user could swap the copy. `logger` names the folder that failed.
    private func trustedFolder(create: Bool, logger: Logger? = nil) -> Bool {
        let expected = folder.absoluteURL
        let home = home.absoluteURL
        guard !expected.pathComponents.contains("."), !expected.pathComponents.contains(".."),
              expected.path.hasPrefix(root.absoluteURL.path + "/"),
              fileSystem.resolve(home) == home.path else { return false }
        var directory = home
        for component in expected.pathComponents.dropFirst(home.pathComponents.count) {
            directory.append(path: component, directoryHint: .isDirectory)
            if create, mkdir(directory.path, 0o700) != 0, errno != EEXIST { return false }
            guard let info = fileSystem.inspect(directory), info.mode & S_IFMT == S_IFDIR,
                  info.owner == geteuid(), info.mode & 0o022 == 0 else {
                let found = fileSystem.inspect(directory).map { "owner \($0.owner), mode \(String($0.mode, radix: 8))" } ?? "missing"
                logger?.error("helper copy: \(directory.path, privacy: .public) must be a real directory of this user without group or world write (\(found, privacy: .public))")
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
              let hash = cdhash(bundle) else { return nil }
        return Stamp(version: version, codeDirectoryHash: hash)
    }

    /// The cdhash of signed code on disk.
    static func cdhash(_ url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoUnique as String] as? Data
    }

    private static func designatedRequirement(of source: URL) -> SecRequirement? {
        var sourceCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(source as CFURL, [], &sourceCode) == errSecSuccess, let sourceCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(sourceCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// Whether `copy` is validly signed (strict, all architectures, nested code)
    /// and satisfies the designated requirement of `source`.
    static func satisfiesDesignatedRequirement(_ copy: URL, of source: URL) -> Bool {
        guard let requirement = designatedRequirement(of: source) else { return false }
        var copyCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(copy as CFURL, [], &copyCode) == errSecSuccess, let copyCode else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        // concurrency-allow: only the verify operation calls it, and only the @concurrent stage(_:) runs that, never main
        return SecStaticCodeCheckValidity(copyCode, flags, requirement) == errSecSuccess
    }
}
