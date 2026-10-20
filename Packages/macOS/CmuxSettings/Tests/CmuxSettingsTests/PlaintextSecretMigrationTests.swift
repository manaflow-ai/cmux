import Foundation
import Testing

@testable import CmuxSettings

@Suite("PlaintextSecretMigration")
struct PlaintextSecretMigrationTests {
    private let keyPath = ["automation", "socketPassword"]

    /// A throwaway directory holding a `cmux.json` for one test.
    private func makeConfig(_ contents: String?) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-secret-migration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cmux.json", isDirectory: false)
        if let contents { try? Data(contents.utf8).write(to: url) }
        return url
    }

    private func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @Test func noFileIsNoOp() {
        let url = makeConfig(nil)
        var saved: [String] = []
        let outcome = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { nil },
            saveSecret: { saved.append($0) },
            backupTimestamp: "T"
        )
        #expect(outcome == .noConfigFile)
        #expect(saved.isEmpty)
    }

    @Test func absentKeyIsNoOp() {
        let url = makeConfig(#"{"automation":{"portBase":9100}}"#)
        var saved: [String] = []
        let outcome = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { nil },
            saveSecret: { saved.append($0) },
            backupTimestamp: "T"
        )
        #expect(outcome == .noPlaintextKey)
        #expect(saved.isEmpty)
        // File untouched (no backup made for a no-op).
        #expect(object(at: url)?["automation"] as? [String: Any] != nil)
    }

    @Test func copiesPlaintextAndScrubsWhenSecretEmpty() throws {
        let url = makeConfig(#"{"automation":{"socketPassword":"hunter2","portBase":9100}}"#)
        var saved: [String] = []
        let outcome = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { nil },
            saveSecret: { saved.append($0) },
            backupTimestamp: "stamp"
        )
        #expect(outcome == .migratedAndScrubbed)
        #expect(saved == ["hunter2"])

        // Plaintext removed, sibling preserved.
        let automation = try #require(object(at: url)?["automation"] as? [String: Any])
        #expect(automation["socketPassword"] == nil)
        #expect(automation["portBase"] as? Int == 9100)

        // Backup of the original exists.
        let backup = url.deletingPathExtension().appendingPathExtension("stamp.bak")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let backupObj = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: backup)
        )) as? [String: Any]
        #expect((backupObj?["automation"] as? [String: Any])?["socketPassword"] as? String == "hunter2")
    }

    @Test func doesNotClobberExistingSecret() throws {
        let url = makeConfig(#"{"automation":{"socketPassword":"fromJSON"}}"#)
        var saved: [String] = []
        let outcome = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { "alreadySecure" },
            saveSecret: { saved.append($0) },
            backupTimestamp: "T"
        )
        #expect(outcome == .scrubbedWithoutCopy)
        #expect(saved.isEmpty)
        // The whole automation object is pruned because it became empty.
        #expect(object(at: url)?["automation"] == nil)
    }

    @Test func prunesEmptiedParentObject() throws {
        let url = makeConfig(#"{"automation":{"socketPassword":"x"},"app":{"appearance":"dark"}}"#)
        let outcome = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { nil },
            saveSecret: { _ in },
            backupTimestamp: "T"
        )
        #expect(outcome == .migratedAndScrubbed)
        let root = try #require(object(at: url))
        #expect(root["automation"] == nil)
        #expect((root["app"] as? [String: Any])?["appearance"] as? String == "dark")
    }

    @Test func toleratesJSONCCommentsAndTrailingCommas() throws {
        let url = makeConfig("""
        {
          // socket automation
          "automation": {
            "socketPassword": "secret", /* inline */
            "portBase": 9100,
          },
        }
        """)
        var saved: [String] = []
        let outcome = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { nil },
            saveSecret: { saved.append($0) },
            backupTimestamp: "T"
        )
        #expect(outcome == .migratedAndScrubbed)
        #expect(saved == ["secret"])
        let automation = try #require(object(at: url)?["automation"] as? [String: Any])
        #expect(automation["socketPassword"] == nil)
        #expect(automation["portBase"] as? Int == 9100)
    }

    @Test func preservesURLInsideStringWhileStrippingComments() throws {
        // A value containing `//` must survive JSONC comment stripping.
        let url = makeConfig("""
        {
          "automation": { "socketPassword": "ab//cd" } // trailing
        }
        """)
        var saved: [String] = []
        _ = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { nil },
            saveSecret: { saved.append($0) },
            backupTimestamp: "T"
        )
        #expect(saved == ["ab//cd"])
    }

    @Test func leavesPlaintextIntactWhenSaveFails() {
        struct SaveError: Error {}
        let raw = #"{"automation":{"socketPassword":"hunter2"}}"#
        let url = makeConfig(raw)
        let outcome = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { nil },
            saveSecret: { _ in throw SaveError() },
            backupTimestamp: "T"
        )
        #expect(outcome == .saveFailedLeftIntact)
        // Config left completely intact so the only copy of the secret survives.
        #expect((try? String(contentsOf: url, encoding: .utf8)) == raw)
        // No backup was made and nothing was scrubbed.
        let backup = url.deletingPathExtension().appendingPathExtension("T.bak")
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func preservesCommaBraceInsideStringValue() throws {
        // A string value containing `, }` must not be corrupted by trailing-comma stripping.
        let url = makeConfig("""
        {
          "automation": {
            "socketPassword": "secret",
            "note": "value, }",
          },
        }
        """)
        var saved: [String] = []
        let outcome = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { nil },
            saveSecret: { saved.append($0) },
            backupTimestamp: "T"
        )
        #expect(outcome == .migratedAndScrubbed)
        #expect(saved == ["secret"])
        let automation = try #require(object(at: url)?["automation"] as? [String: Any])
        #expect(automation["socketPassword"] == nil)
        #expect(automation["note"] as? String == "value, }")
    }

    @Test func leavesUnparseableFileIntact() {
        let raw = "{ this is not json and has socketPassword somewhere"
        let url = makeConfig(raw)
        var saved: [String] = []
        let outcome = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { nil },
            saveSecret: { saved.append($0) },
            backupTimestamp: "T"
        )
        #expect(outcome == .parseFailedLeftIntact)
        #expect(saved.isEmpty)
        #expect((try? String(contentsOf: url, encoding: .utf8)) == raw)
    }

    @Test func isIdempotent() {
        let url = makeConfig(#"{"automation":{"socketPassword":"x"}}"#)
        var saved: [String] = []
        let first = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { saved.last },
            saveSecret: { saved.append($0) },
            backupTimestamp: "T1"
        )
        let second = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { saved.last },
            saveSecret: { saved.append($0) },
            backupTimestamp: "T2"
        )
        #expect(first == .migratedAndScrubbed)
        #expect(second == .noPlaintextKey)
        #expect(saved == ["x"])
    }
}
