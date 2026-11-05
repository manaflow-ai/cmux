import Foundation
import Testing
@testable import CmuxNextCloud

/// The explicit credentials file a shipped build signs in from (``DogfoodCredentials/decide(environment:home:requireOwnedDirectories:read:)``):
/// a regular 0600 file of this user, in directories no other account can write.
struct DogfoodCredentialsFileTests {
    private let contents = "CMUX_UITEST_STACK_EMAIL=ci@example.com\nCMUX_UITEST_STACK_PASSWORD=not-a-real-password\n"

    /// A fresh directory of this user under the per-user temporary directory (0700, parents root or this user).
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dogfood-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return dir
    }

    private func write(_ dir: URL, mode: Int) throws -> String {
        let file = dir.appendingPathComponent("creds.env")
        try contents.write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return file.path
    }

    private func decide(_ path: String) -> (credentials: DogfoodCredentials?, refusal: DogfoodCredentials.Refusal?) {
        DogfoodCredentials.decide(environment: ["CMUX_AUTH_CREDENTIALS_FILE": path], home: "/nonexistent", requireOwnedDirectories: true)
    }

    @Test func aPrivateFileOfThisUserSignsIn() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = decide(try write(dir, mode: 0o600))
        #expect(result.credentials == DogfoodCredentials(email: "ci@example.com", password: "not-a-real-password"))
        #expect(result.refusal == nil)
    }

    @Test func aFileOthersCanReadIsRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = decide(try write(dir, mode: 0o644))
        #expect(result.credentials == nil)
        #expect(result.refusal == .unsafeCredentialsFile)
    }

    @Test func aFileUnderAWorldWritableDirectoryIsRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = dir.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o777])
        let result = decide(try write(shared, mode: 0o600))
        #expect(result.credentials == nil)
        #expect(result.refusal == .unsafeCredentialsFile)
        // /tmp (sticky, world-writable) is never trusted either.
        #expect(!DogfoodCredentials.ownedDirectories(above: "/tmp/creds.env"))
    }

    @Test func aSymlinkToAPrivateFileIsRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = try write(dir, mode: 0o600)
        let link = dir.appendingPathComponent("link.env")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        #expect(decide(link.path).refusal == .unsafeCredentialsFile)
    }

    @Test func aMissingFileIsRefused() {
        #expect(decide("/nonexistent/creds.env").refusal == .unsafeCredentialsFile)
    }

    /// A debug or signed NEXT DEV launch keeps its old rule: no directory check, a bad file is simply no sign-in.
    @Test func otherLaunchesKeepTheOldRule() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = DogfoodCredentials.decide(environment: ["CMUX_AUTH_CREDENTIALS_FILE": try write(dir, mode: 0o644)], home: "/nonexistent")
        #expect(result.credentials == nil)
        #expect(result.refusal == nil)
    }
}
