import Foundation
import Testing
@testable import CmuxDockExtensions

@Suite("InstalledDockExtensionsRepository")
struct InstalledDockExtensionsRepositoryTests {
    private func makeTempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ext-repo-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("extensions.json", isDirectory: false)
    }

    private func makeRecord(id: String = "token-usage") -> DockExtensionInstallRecord {
        DockExtensionInstallRecord(
            id: id,
            source: .github(owner: "o", repository: "r", subdirectory: nil),
            pinnedSha: String(repeating: "a", count: 40),
            ref: "main",
            installedAt: Date(timeIntervalSince1970: 1_750_000_000),
            enabled: true,
            consentFingerprint: "fp"
        )
    }

    @Test func missingFileLoadsEmpty() async throws {
        let repository = InstalledDockExtensionsRepository(fileURL: makeTempFile())
        let lockFile = try await repository.load()
        #expect(lockFile == .empty)
    }

    @Test func upsertRemoveRoundTrip() async throws {
        let fileURL = makeTempFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let repository = InstalledDockExtensionsRepository(fileURL: fileURL)

        var lockFile = try await repository.upsert(makeRecord())
        #expect(lockFile.extensions.count == 1)

        // Replaces by id.
        var updated = makeRecord()
        updated.enabled = false
        lockFile = try await repository.upsert(updated)
        #expect(lockFile.extensions.count == 1)
        #expect(lockFile.extensions[0].enabled == false)

        // Fresh repository over the same file sees the same content.
        let reread = try await InstalledDockExtensionsRepository(fileURL: fileURL).load()
        #expect(reread == lockFile)

        lockFile = try await repository.remove(id: "token-usage")
        #expect(lockFile.extensions.isEmpty)
    }

    @Test func updateRecordMutatesInPlace() async throws {
        let fileURL = makeTempFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let repository = InstalledDockExtensionsRepository(fileURL: fileURL)
        _ = try await repository.upsert(makeRecord())
        let lockFile = try await repository.updateRecord(id: "token-usage") { $0.enabled = false }
        #expect(lockFile.extensions[0].enabled == false)

        await #expect(throws: DockExtensionError.notInstalled(id: "ghost")) {
            try await repository.updateRecord(id: "ghost") { _ in }
        }
    }

    @Test func corruptFileThrowsInsteadOfClobbering() async throws {
        let fileURL = makeTempFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json{".utf8).write(to: fileURL)
        let repository = InstalledDockExtensionsRepository(fileURL: fileURL)
        await #expect(throws: Error.self) {
            _ = try await repository.load()
        }
        // The corrupt content is untouched.
        #expect(try Data(contentsOf: fileURL) == Data("not json{".utf8))
    }

    @Test func localSourceRoundTrips() async throws {
        let fileURL = makeTempFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let repository = InstalledDockExtensionsRepository(fileURL: fileURL)
        let record = DockExtensionInstallRecord(
            id: "dev",
            source: .local(path: "/Users/dev/my-ext"),
            pinnedSha: nil,
            installedAt: Date(timeIntervalSince1970: 1_750_000_000),
            consentFingerprint: "fp"
        )
        _ = try await repository.upsert(record)
        let reread = try await repository.load()
        #expect(reread.extensions == [record])
    }
}
