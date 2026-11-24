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

    /// Two cmux builds running side by side must not share `cmux ssh` masters: on a host that
    /// allows one session per connection, the second build's connection was refused outright.
    @Test("Each cmux build gets its own private directory, and the release app keeps the shared one")
    func eachBuildGetsItsOwnDirectory() throws {
        // A short home: the nested directory needs nine bytes the shared one does not.
        let home = try TemporaryHome(template: "/tmp/cmh.XXXX")
        defer { home.remove() }
        let release = try #require(SSHControlSocketDirectory.prepare(
            home: home.path, userID: userID,
            build: SSHControlSocketBuildIdentity(bundleIdentifier: "com.cmuxterm.app")))
        let nightly = try #require(SSHControlSocketDirectory.prepare(
            home: home.path, userID: userID,
            build: SSHControlSocketBuildIdentity(bundleIdentifier: "com.cmuxterm.app.nightly")))
        let tagged = try #require(SSHControlSocketDirectory.prepare(
            home: home.path, userID: userID,
            build: SSHControlSocketBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.feature")))

        #expect(release == home.resolvedPath + "/.cmux/ssh")
        #expect(Set([release, nightly, tagged]).count == 3)
        #expect(nightly.hasPrefix(release + "/") && tagged.hasPrefix(release + "/"))
        for directory in [nightly, tagged] {
            var info = stat()
            try #require(lstat(directory, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o700)
            #expect(SSHControlSocketDirectory.isUsable(directory))
        }
    }

    /// The bundled CLI has no bundle identifier of its own, so it must name the app it lives in.
    /// Otherwise a tagged build's app and its CLI would put the same host's master in different
    /// directories.
    @Test("The bundled CLI takes its namespace from the app it sits in, through symlinks")
    func bundledCLIUsesItsAppsIdentifier() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let app = home.path + "/cmux DEV feature.app"
        let bin = app + "/Contents/Resources/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.cmuxterm.app.debug.feature", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
        FileManager.default.createFile(atPath: bin + "/cmux", contents: Data())
        let link = home.path + "/cmux-on-path"
        try #require(symlink(bin + "/cmux", link) == 0)

        #expect(SSHControlSocketBuildIdentity(
            bundleIdentifier: nil, executableURL: URL(fileURLWithPath: link)
        ).namespace == "com.cmuxterm.app.debug.feature")
        #expect(SSHControlSocketBuildIdentity(
            bundleIdentifier: nil, executableURL: URL(fileURLWithPath: home.path + "/loose-cli")
        ).namespace == nil)
    }
}

/// A short home under `/tmp`, since the per-user temporary directory is too
/// long to hold a control socket path.
private struct TemporaryHome {
    let path: String
    let resolvedPath: String

    init(template templatePath: String = "/tmp/cmux-home.XXXXXX") throws {
        var template = Array(templatePath.utf8CString)
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
