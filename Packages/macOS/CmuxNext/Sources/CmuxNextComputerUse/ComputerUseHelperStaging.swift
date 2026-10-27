// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxNextAgentActivity
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

    /// The file and signature work (the real ones by default, fakes in tests).
    struct Operations: Sendable {
        /// Copies the bundle at `source` to the new path `destination` without quarantine.
        var copy: @Sendable (_ source: URL, _ destination: URL) async -> Bool
        /// The bundle's version and code directory hash; nil when unsigned or unreadable.
        var stamp: @Sendable (URL) -> Stamp?
        /// Whether `copy` passes the signature check that `source` passed.
        var verify: @Sendable (_ copy: URL, _ source: URL) -> Bool

        static func system(verify: @escaping @Sendable (_ copy: URL, _ source: URL) -> Bool) -> Operations {
            Operations(copy: { await ComputerUseHelperStaging.ditto($0, $1) },
                       stamp: { ComputerUseHelperStaging.readStamp($0) },
                       verify: verify)
        }
    }

    /// The private folder that holds the copy (one per app build).
    let folder: URL
    let operations: Operations

    init(folder: URL, operations: Operations) {
        self.folder = folder
        self.operations = operations
    }

    /// The legacy helper's copy: `.../cmux-cua/helper/next-<scope>/cmux Computer Use.app`,
    /// checked against the release helper's Developer ID requirement.
    static func legacy(bundleID: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ComputerUseHelperStaging {
        ComputerUseHelperStaging(folder: root(home: home).appending(path: "next-\(ComputerUseHelperDaemon.scope(bundleID))",
                                                                   directoryHint: .isDirectory),
                                 operations: .system { copy, _ in CuaHelperIdentity.satisfiesRequirement(copy) })
    }

    /// The helper v2's copy: `.../cmux-cua/helper/next-v2-<scope>/<its name>`, checked
    /// against the source's own designated requirement.
    static func upstream(bundleID: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ComputerUseHelperStaging {
        ComputerUseHelperStaging(folder: root(home: home).appending(path: "next-v2-\(ComputerUseHelperDaemon.scope(bundleID))",
                                                                   directoryHint: .isDirectory),
                                 operations: .system { copy, source in ComputerUseHelperStaging.satisfiesDesignatedRequirement(copy, of: source) })
    }

    /// `~/Library/Application Support/cmux/cmux-cua/helper`, where classic cmux keeps its copies too.
    /// The `next-` names keep the classic installer away from these.
    static func root(home: URL) -> URL {
        home.appending(path: "Library/Application Support/cmux/cmux-cua/helper", directoryHint: .isDirectory)
    }

    /// Where the copy of `source` goes.
    func destination(for source: URL) -> URL {
        folder.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
    }

    /// The copy of the helper named `appName` when it is in place and passes
    /// its signature check (for the setup's "drag this app" tile), else nil.
    @concurrent func existingCopy(named appName: String) async -> URL? {
        nil
    }

    /// Base behavior: the helper runs where it is installed (red step).
    @concurrent func stage(_ source: URL) async -> URL? {
        source
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
        guard let data = try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let version = plist["CFBundleVersion"] as? String,
              let hash = ComputerUseHelperV2.cdhash(bundle) else { return nil }
        return Stamp(version: version, codeDirectoryHash: hash)
    }

    /// Whether `copy` is validly signed (strict, all architectures, nested code)
    /// and satisfies the designated requirement of `source`.
    static func satisfiesDesignatedRequirement(_ copy: URL, of source: URL) -> Bool {
        var sourceCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(source as CFURL, [], &sourceCode) == errSecSuccess, let sourceCode else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(sourceCode, [], &requirement) == errSecSuccess, let requirement else { return false }
        var copyCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(copy as CFURL, [], &copyCode) == errSecSuccess, let copyCode else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(copyCode, flags, requirement) == errSecSuccess
    }
}
