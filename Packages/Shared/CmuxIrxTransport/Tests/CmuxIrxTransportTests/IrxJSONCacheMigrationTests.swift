import Foundation
import Testing

@testable import CmuxIrxTransport

/// In-memory primary standing in for the Release keychain cache (SPM tests
/// have no keychain entitlement; the migration logic is backend-agnostic).
private final class InMemoryJSONCache<Value: Codable & Sendable>: IrxJSONCache, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private(set) var saveCount = 0

    func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    func save(_ newValue: Value) -> Bool {
        lock.lock()
        value = newValue
        saveCount += 1
        lock.unlock()
        return true
    }

    func clear() {
        lock.lock()
        value = nil
        lock.unlock()
    }
}

@Suite("broker cache keychain migration")
struct IrxJSONCacheMigrationTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("irx-cache-migration-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("binding.json")
    }

    @Test func firstLoadMigratesLegacyFileAndDeletesIt() throws {
        let fileURL = temporaryFile()
        let legacy = IrxDiskCache<[String: Int]>(fileURL: fileURL)
        legacy.save(["rev": 4])
        let primary = InMemoryJSONCache<[String: Int]>()
        let migrating = IrxMigratingJSONCache(primary: primary, legacy: legacy)

        #expect(migrating.load() == ["rev": 4])
        // Migration is one-way: the value now lives in the primary and the
        // legacy file is gone.
        #expect(primary.load() == ["rev": 4])
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func migrationIsIdempotentAcrossRepeatedLoads() throws {
        let fileURL = temporaryFile()
        let legacy = IrxDiskCache<[String: Int]>(fileURL: fileURL)
        legacy.save(["rev": 4])
        let primary = InMemoryJSONCache<[String: Int]>()
        let migrating = IrxMigratingJSONCache(primary: primary, legacy: legacy)

        #expect(migrating.load() == ["rev": 4])
        #expect(migrating.load() == ["rev": 4])
        #expect(migrating.load() == ["rev": 4])
        #expect(primary.saveCount == 1)
    }

    @Test func primaryWinsOverAResurrectedLegacyFile() throws {
        let fileURL = temporaryFile()
        let legacy = IrxDiskCache<[String: Int]>(fileURL: fileURL)
        let primary = InMemoryJSONCache<[String: Int]>()
        primary.save(["rev": 9])
        let migrating = IrxMigratingJSONCache(primary: primary, legacy: legacy)
        // A stale file written later (old build, restored backup) is ignored
        // while the primary holds a value.
        legacy.save(["rev": 1])
        #expect(migrating.load() == ["rev": 9])
    }

    @Test func saveWritesPrimaryAndDropsLegacy() throws {
        let fileURL = temporaryFile()
        let legacy = IrxDiskCache<[String: Int]>(fileURL: fileURL)
        legacy.save(["rev": 1])
        let primary = InMemoryJSONCache<[String: Int]>()
        let migrating = IrxMigratingJSONCache(primary: primary, legacy: legacy)

        migrating.save(["rev": 2])
        #expect(primary.load() == ["rev": 2])
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(migrating.load() == ["rev": 2])
    }

    @Test func emptyBothSidesLoadsNil() throws {
        let migrating = IrxMigratingJSONCache(
            primary: InMemoryJSONCache<[String: Int]>(),
            legacy: IrxDiskCache<[String: Int]>(fileURL: temporaryFile())
        )
        #expect(migrating.load() == nil)
    }

    @Test func failedPrimaryWriteKeepsLegacyFile() throws {
        let fileURL = temporaryFile()
        let legacy = IrxDiskCache<[String: Int]>(fileURL: fileURL)
        legacy.save(["rev": 4])
        let primary = FailingJSONCache<[String: Int]>()
        let migrating = IrxMigratingJSONCache(primary: primary, legacy: legacy)

        #expect(migrating.load() == ["rev": 4])
        #expect(legacy.load() == ["rev": 4])
    }

    @Test func clearRemovesBothSides() throws {
        let fileURL = temporaryFile()
        let legacy = IrxDiskCache<[String: Int]>(fileURL: fileURL)
        legacy.save(["rev": 1])
        let primary = InMemoryJSONCache<[String: Int]>()
        primary.save(["rev": 2])
        let migrating = IrxMigratingJSONCache(primary: primary, legacy: legacy)
        migrating.clear()
        #expect(migrating.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }
}

private struct FailingJSONCache<Value: Codable & Sendable>: IrxJSONCache {
    func load() -> Value? { nil }
    @discardableResult
    func save(_ value: Value) -> Bool { false }
    func clear() {}
}
