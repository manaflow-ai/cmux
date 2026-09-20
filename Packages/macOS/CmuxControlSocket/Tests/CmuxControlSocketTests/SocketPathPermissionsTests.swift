import Darwin
import Foundation
import Testing
@testable import CmuxControlSocket

@Suite struct SocketPathPermissionsTests {
    @Test func changesOwnedInodeAndCleansAnchor() throws {
        let fixture = try PermissionsFixture()
        defer { fixture.cleanup() }
        #expect(SocketPathPermissions.apply(to: fixture.path, matching: fixture.identity, permissions: 0o666) == nil)
        #expect(try fixture.mode(at: fixture.path) == 0o666)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory) == ["socket"])
    }

    @Test(arguments: ["file", "socket", "symlink"])
    func replacementBetweenValidationAndMutationIsPreserved(kind: String) throws {
        let fixture = try PermissionsFixture()
        defer { fixture.cleanup() }
        var replacementFD: Int32 = -1
        defer { if replacementFD >= 0 { close(replacementFD) } }
        let result = SocketPathPermissions.apply(
            to: fixture.path, matching: fixture.identity, permissions: 0o666,
            beforeMutation: {
                #expect(rename(fixture.path, fixture.directory + "/original") == 0)
                if kind == "socket" {
                    replacementFD = (try? PermissionsFixture.bind(fixture.path)) ?? -1
                    #expect(replacementFD >= 0)
                } else if kind == "symlink" {
                    let target = fixture.directory + "/target"
                    #expect(FileManager.default.createFile(atPath: target, contents: Data("replacement".utf8)))
                    #expect(chmod(target, 0o640) == 0)
                    #expect(symlink(target, fixture.path) == 0)
                } else {
                    #expect(FileManager.default.createFile(atPath: fixture.path, contents: Data("replacement".utf8)))
                }
                if kind != "symlink" { #expect(chmod(fixture.path, 0o640) == 0) }
            }
        )
        #expect(result == ESTALE)
        #expect(try fixture.mode(at: fixture.path) == 0o640)
        if kind != "socket" {
            #expect(try String(contentsOfFile: fixture.path, encoding: .utf8) == "replacement")
        }
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: fixture.directory)).contains { $0.hasPrefix(".cmux-permissions-") })
    }

    @Test func rejectsReplacementBeforePinning() throws {
        let fixture = try PermissionsFixture()
        defer { fixture.cleanup() }
        #expect(rename(fixture.path, fixture.directory + "/original") == 0)
        let replacementFD = try PermissionsFixture.bind(fixture.path)
        defer { close(replacementFD) }
        #expect(chmod(fixture.path, 0o640) == 0)
        #expect(SocketPathPermissions.apply(to: fixture.path, matching: fixture.identity, permissions: 0o666) == ESTALE)
        #expect(try fixture.mode(at: fixture.path) == 0o640)
    }
}

private struct PermissionsFixture {
    let directory: String
    let path: String
    let fd: Int32
    let identity: SocketPathIdentity

    init() throws {
        directory = "/tmp/cmux-perm-" + String(UUID().uuidString.prefix(8))
        path = directory + "/socket"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        fd = try Self.bind(path)
        var info = stat()
        #expect(lstat(path, &info) == 0)
        identity = SocketPathIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    static func bind(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                    _ = strcpy(destination, source)
                }
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 { close(fd) }
        try #require(result == 0)
        return fd
    }

    func mode(at path: String) throws -> mode_t {
        var info = stat()
        try #require(stat(path, &info) == 0)
        return info.st_mode & 0o777
    }

    func cleanup() {
        close(fd)
        try? FileManager.default.removeItem(atPath: directory)
    }
}
