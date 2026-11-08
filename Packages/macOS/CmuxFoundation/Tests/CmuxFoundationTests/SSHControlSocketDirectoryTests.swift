import Darwin
import Foundation
import Testing
@testable import CmuxFoundation

@Suite("SSH control socket directory")
struct SSHControlSocketDirectoryTests {
    private let userID = Int(getuid())

    @Test("A fresh home gets a directory only this user can use")
    func createsPrivateDirectory() throws {
        let home = try TemporaryHome()
        defer { home.remove() }

        let directory = try #require(SSHControlSocketDirectory.prepare(home: home.path, userID: userID))

        #expect(directory == home.resolvedPath + "/.cmux/ssh")
        var info = stat()
        try #require(lstat(directory, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(Int(info.st_uid) == userID)
    }

    @Test("An existing private directory is reused")
    func reusesExistingDirectory() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let first = SSHControlSocketDirectory.prepare(home: home.path, userID: userID)

        #expect(first != nil)
        #expect(SSHControlSocketDirectory.prepare(home: home.path, userID: userID) == first)
    }

    @Test("A directory other users can write to is refused", arguments: [
        (".cmux", mode_t(0o777)),
        (".cmux", mode_t(0o775)),
        (".cmux/ssh", mode_t(0o777)),
        (".cmux/ssh", mode_t(0o720)),
    ])
    func refusesWritableDirectory(component: String, mode: mode_t) throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        #expect(SSHControlSocketDirectory.prepare(home: home.path, userID: userID) != nil)
        try #require(chmod(home.path + "/" + component, mode) == 0)

        #expect(SSHControlSocketDirectory.prepare(home: home.path, userID: userID) == nil)
    }

    @Test("A socket directory that links into shared /tmp is refused")
    func refusesLinkToSharedTemporaryDirectory() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try #require(mkdir(home.path + "/.cmux", 0o700) == 0)
        try #require(symlink("/tmp", home.path + "/.cmux/ssh") == 0)

        #expect(SSHControlSocketDirectory.prepare(home: home.path, userID: userID) == nil)
    }

    @Test("A directory owned by another user is refused")
    func refusesAnotherUsersDirectory() throws {
        let home = try TemporaryHome()
        defer { home.remove() }

        #expect(SSHControlSocketDirectory.prepare(home: home.path, userID: userID + 1) == nil)
    }

    @Test("A home too long for a socket path is refused")
    func refusesLongHome() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let longHome = home.path + "/" + String(repeating: "h", count: 40)
        try #require(mkdir(longHome, 0o700) == 0)

        #expect(SSHControlSocketDirectory.prepare(home: longHome, userID: userID) == nil)
    }

    @Test("A relative home is refused")
    func refusesRelativeHome() {
        #expect(SSHControlSocketDirectory.prepare(home: "relative-home", userID: userID) == nil)
    }
}

/// A short home under `/tmp`, since the per-user temporary directory is too
/// long to hold a control socket path.
private struct TemporaryHome {
    let path: String
    let resolvedPath: String

    init() throws {
        var template = Array("/tmp/cmux-home.XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        path = String(cString: created)
        guard let resolved = realpath(path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        resolvedPath = String(cString: resolved)
        free(resolved)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
