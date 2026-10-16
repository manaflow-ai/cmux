import Darwin
import Foundation
import Testing
@testable import CmuxFoundation

/// OpenSSH connects to any socket at `ControlPath` and hands it the session's
/// terminal, whoever made the socket. cmux's socket must therefore live where
/// no other local user can create one first.
@Suite("SSH control socket privacy")
struct SSHControlSocketPrivacyTests {
    private static let userID = Int(getuid())

    /// The flat `/tmp` paths older cmux builds used, template and resolved,
    /// with and without a workspace relay port.
    private static let sharedTemporaryPaths = [
        "/tmp/cmux-ssh-\(userID)-%C",
        "/tmp/cmux-ssh-\(userID)-0123456789abcdef0123456789abcdef01234567",
        "/tmp/cmux-ssh-\(userID)-64001-%C",
        "/tmp/cmux-ssh-\(userID)-64001-0123456789abcdef0123456789abcdef01234567",
    ]

    @Test("cmux's default control socket is in a directory only this user can write")
    func defaultControlSocketDirectoryIsPrivate() throws {
        let merged = SSHConnectionSharingOptions().mergingDefaults(into: [])
        // No ControlPath means no sharing, which is safe too.
        guard let path = controlPath(in: merged) else { return }
        #expect(!Self.isInSharedTemporaryDirectory(path), "\(path)")
        let directory = (path as NSString).deletingLastPathComponent
        var info = stat()
        try #require(lstat(directory, &info) == 0, "\(directory) must exist before ssh binds in it")
        #expect(info.st_mode & S_IFMT == S_IFDIR, "\(directory) must be a real directory")
        #expect(Int(info.st_uid) == Self.userID, "\(directory) must belong to this user")
        #expect(info.st_mode & 0o022 == 0, "\(directory) must not be writable by other users")
    }

    @Test("A /tmp control socket from an older cmux never reaches ssh",
          arguments: sharedTemporaryPaths, [nil, "ControlMaster=auto", "ControlMaster=no"])
    func sharedTemporaryPathIsReplaced(path: String, controlMaster: String?) {
        let supplied = [controlMaster, "ControlPath=\(path)"].compactMap { $0 }
        let merged = SSHConnectionSharingOptions().mergingDefaults(into: supplied)
        // ControlMaster=no still connects to an existing socket at ControlPath.
        let effective = controlPath(in: merged)
        #expect(effective.map(Self.isInSharedTemporaryDirectory) != true, "\(merged)")
    }

    @Test("cmux never checks or removes a /tmp control socket as its own", arguments: sharedTemporaryPaths)
    func sharedTemporaryPathIsNotOwned(path: String) {
        let options = SSHConnectionSharingOptions()
        let supplied = ["ControlMaster=auto", "ControlPath=\(path)"]
        #expect(options.cmuxOwnedControlPath(in: supplied) == nil)
        #expect(options.controlPathPreflightShellFunction(
            sshArguments: ["/usr/bin/ssh"], destination: "alice@example.invalid", options: supplied
        ) == nil)
    }

    @Test("The stale-socket cleanup only matches cmux's private directory")
    func preflightMatchesOnlyThePrivateDirectory() {
        let options = SSHConnectionSharingOptions()
        let merged = options.mergingDefaults(into: [])
        guard let function = options.controlPathPreflightShellFunction(
            sshArguments: ["/usr/bin/ssh"], destination: "alice@example.invalid", options: merged
        ) else { return }
        #expect(!function.contains("/tmp/"), "\(function)")
    }

    private func controlPath(in options: [String]) -> String? {
        SSHAgentSocketResolver().optionValue(named: "ControlPath", in: options)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.lowercased() == "none" ? nil : $0 }
    }

    private static func isInSharedTemporaryDirectory(_ path: String) -> Bool {
        path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/")
    }
}
