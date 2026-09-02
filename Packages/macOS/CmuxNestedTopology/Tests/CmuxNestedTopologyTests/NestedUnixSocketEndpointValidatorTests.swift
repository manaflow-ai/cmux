#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct NestedUnixSocketEndpointValidatorTests {
    @Test func acceptsOwnerOnlyUnixSocketAndPinsIdentity() throws {
        let server = try FakeHerdrUnixSocketServer { _, id, _ in
            [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id))]
        }
        defer { server.shutdown() }
        try chmodPath(server.path, mode: 0o600)

        let validator = NestedUnixSocketEndpointValidator(expectedOwnerUID: geteuid())
        let endpoint = try validator.validatePreConnect(path: server.path)
        #expect(endpoint.canonicalPath.hasPrefix("/"))
        #expect(endpoint.permissionBits == 0o600)
        #expect(endpoint.ownerUID == UInt32(geteuid()))
        try validator.revalidateIdentity(
            path: endpoint.canonicalPath,
            expected: endpoint.fileIdentity
        )
    }

    @Test func rejectsSymlinkFinalComponent() throws {
        let server = try FakeHerdrUnixSocketServer { _, id, _ in
            [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id))]
        }
        defer { server.shutdown() }
        try chmodPath(server.path, mode: 0o600)

        let linkPath = NSTemporaryDirectory() + "herdr-link-\(UUID().uuidString.prefix(8)).sock"
        unlink(linkPath)
        guard symlink(server.path, linkPath) == 0 else {
            Issue.record("symlink() failed errno=\(errno)")
            return
        }
        defer { unlink(linkPath) }

        let validator = NestedUnixSocketEndpointValidator(expectedOwnerUID: geteuid())
        do {
            _ = try validator.validatePreConnect(path: linkPath)
            Issue.record("expected symlink rejection")
        } catch let error as NestedEndpointSecurityError {
            #expect(error == .symlinkRejected)
            #expect(error.telemetryErrorClass == "symlink_rejected")
        }
    }

    @Test func rejectsWrongOwner() throws {
        let server = try FakeHerdrUnixSocketServer { _, id, _ in
            [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id))]
        }
        defer { server.shutdown() }
        try chmodPath(server.path, mode: 0o600)

        let otherUID = geteuid() &+ 1
        let validator = NestedUnixSocketEndpointValidator(expectedOwnerUID: otherUID)
        do {
            _ = try validator.validatePreConnect(path: server.path)
            Issue.record("expected wrong owner rejection")
        } catch let error as NestedEndpointSecurityError {
            guard case .wrongOwner(let expected, let actual) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(expected == UInt32(otherUID))
            #expect(actual == UInt32(geteuid()))
        }
    }

    @Test func rejectsPermissiveMode() throws {
        let server = try FakeHerdrUnixSocketServer { _, id, _ in
            [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id))]
        }
        defer { server.shutdown() }
        try chmodPath(server.path, mode: 0o666)

        let validator = NestedUnixSocketEndpointValidator(expectedOwnerUID: geteuid())
        do {
            _ = try validator.validatePreConnect(path: server.path)
            Issue.record("expected permissive mode rejection")
        } catch let error as NestedEndpointSecurityError {
            guard case .permissiveMode(let mode) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(mode == 0o666)
        }
    }

    @Test func rejectsRegularFileType() throws {
        let filePath = NSTemporaryDirectory() + "herdr-not-sock-\(UUID().uuidString.prefix(8))"
        #expect(FileManager.default.createFile(atPath: filePath, contents: Data("x".utf8)))
        defer { try? FileManager.default.removeItem(atPath: filePath) }
        try chmodPath(filePath, mode: 0o600)

        let validator = NestedUnixSocketEndpointValidator(expectedOwnerUID: geteuid())
        do {
            _ = try validator.validatePreConnect(path: filePath)
            Issue.record("expected notUnixSocket")
        } catch let error as NestedEndpointSecurityError {
            #expect(error == .notUnixSocket)
        }
    }

    @Test func rejectsRelativePathAndDetectsIdentitySwap() throws {
        let validator = NestedUnixSocketEndpointValidator(expectedOwnerUID: geteuid())
        do {
            _ = try validator.validatePreConnect(path: "relative.sock")
            Issue.record("expected notAbsolutePath")
        } catch let error as NestedEndpointSecurityError {
            #expect(error == .notAbsolutePath)
        }

        let serverA = try FakeHerdrUnixSocketServer { _, id, _ in
            [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id))]
        }
        defer { serverA.shutdown() }
        try chmodPath(serverA.path, mode: 0o600)
        let endpoint = try validator.validatePreConnect(path: serverA.path)

        let serverB = try FakeHerdrUnixSocketServer { _, id, _ in
            [HerdrFakeFixtures.line(HerdrFakeFixtures.pongJSON(id: id))]
        }
        defer { serverB.shutdown() }
        try chmodPath(serverB.path, mode: 0o600)

        // Replace path A with a different socket inode (unlink + bind already unique path;
        // instead revalidate against B's identity using A's path after swap via rename).
        unlink(serverA.path)
        guard rename(serverB.path, serverA.path) == 0 else {
            Issue.record("rename() failed errno=\(errno)")
            return
        }

        do {
            try validator.revalidateIdentity(
                path: serverA.path,
                expected: endpoint.fileIdentity
            )
            Issue.record("expected identity mismatch after path replacement")
        } catch let error as NestedEndpointSecurityError {
            guard case .identityMismatch = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test func sanitizeStripsControlsAndTruncates() {
        let dirty = "ab\u{0007}c\n\td"
        #expect(NestedDisplayStringSanitizer.sanitize(dirty) == "abcd")
        let long = String(repeating: "字", count: 20)
        let truncated = NestedDisplayStringSanitizer.sanitize(long, maxUTF8ByteCount: 10)
        #expect(truncated.utf8.count <= 10)
        #expect(!truncated.isEmpty)
    }
}

private func chmodPath(_ path: String, mode: mode_t) throws {
    guard chmod(path, mode) == 0 else {
        throw NSError(
            domain: "NestedUnixSocketEndpointValidatorTests",
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "chmod failed"]
        )
    }
}
