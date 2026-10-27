import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextDaemon

/// p15-oracle-130: the install key store comes from the signing team the composition root injects, never from a
/// signature read of its own, and an unsigned build (every Linux build) keeps its key in an owner-only 0600 file.
@Suite struct FrontendInstallKeyStoresTests {
    private static func stateDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("install-key-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func aSignedBuildGetsNoStoreAndWritesNothing() {
        let directory = Self.stateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(FrontendInstallKeyStores(team: { "ABCDE12345" }).forApp(stateDirectory: directory) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func noStateDirectoryGetsNoStore() {
        #expect(FrontendInstallKeyStores(team: { nil }).forApp(stateDirectory: nil) == nil)
    }

    @Test func anUnsignedBuildKeepsOneKeyInAnOwnerOnlyFile() throws {
        let directory = Self.stateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(FrontendInstallKeyStores(team: { nil }).forApp(stateDirectory: directory))
        let key = try #require(store.loadOrCreate())
        let file = directory.appendingPathComponent("frontend-install-key")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(store.loadOrCreate() == key)
        // A key another user could read is not this app's.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(store.loadOrCreate() == nil)
    }

    /// A launcher's key is read on the lanes (the team on the system lane, the file on the files lane), once.
    @Test func aLaunchersKeyIsReadOnceOnTheLanes() async throws {
        let work = BackgroundWork(label: "test.install-key")
        let directory = Self.stateDirectory()
        let signedDirectory = Self.stateDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: signedDirectory)
        }
        let source = FrontendInstallKeyStores(team: { nil }).read(stateDirectory: directory, on: work)
        let key = try #require(await source.key())
        #expect(await source.key() == key)
        #expect(FrontendInstallKeyStores(team: { nil }).forApp(stateDirectory: directory)?.loadOrCreate() == key)

        #expect(await FrontendInstallKeyStores(team: { "ABCDE12345" }).read(stateDirectory: signedDirectory, on: work).key() == nil)
        #expect(!FileManager.default.fileExists(atPath: signedDirectory.path))
        #expect(await FrontendInstallKeyStores(team: { nil }).read(stateDirectory: nil, on: work).key() == nil)
    }
}
