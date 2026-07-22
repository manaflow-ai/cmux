import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite(.serialized)
struct CmxIrohDevelopmentFileStorageTests {
    @Test func identityRoundTripsWithPrivateFilesystemPermissions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = CmxIrohDevelopmentFileIdentityStore(
            directory: fixture.directory
        )

        try store.write(Data([1, 2, 3]), account: "identity-scope")

        #expect(try store.read(account: "identity-scope") == Data([1, 2, 3]))
        #expect(try fixture.permissions(at: fixture.directory) == 0o700)
        #expect(try fixture.permissions(
            at: fixture.directory.appendingPathComponent(
                "identity-scope.cmux-iroh"
            )
        ) == 0o600)
    }

    @Test func credentialStoreDeletesOnlyItsRecords() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.directory,
            withIntermediateDirectories: true
        )
        let unrelated = fixture.directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let store = CmxIrohDevelopmentFileCredentialStore(
            directory: fixture.directory
        )

        try await store.write(
            Data("one".utf8),
            account: "active-host-policy",
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        try await store.write(
            Data("two".utf8),
            account: "active-client-policies",
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        try await store.deleteAll()

        #expect(try await store.read(account: "active-host-policy") == nil)
        #expect(try await store.read(account: "active-client-policies") == nil)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func traversalScopeIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = CmxIrohDevelopmentFileIdentityStore(
            directory: fixture.directory
        )

        #expect(throws: CmxIrohDevelopmentFileStoreError.invalidAccount) {
            try store.write(Data([1]), account: "../outside")
        }
    }

    private struct Fixture {
        let root: URL
        let directory: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cmux-iroh-development-store-\(UUID().uuidString)",
                isDirectory: true
            )
            directory = root.appendingPathComponent("store", isDirectory: true)
        }

        func permissions(at url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
