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
        // The scrub keeps the file's comments, so read it as JSONC.
        guard let data = try? Data(contentsOf: url),
              let sanitized = try? JSONCSanitizer().sanitize(data) else { return nil }
        return (try? JSONSerialization.jsonObject(with: sanitized)) as? [String: Any]
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

    @Test func absentKeyDoesNotCreateWriterLockSidecar() {
        // The sidecar is never deleted, so a launch with nothing to scrub must
        // not leave one beside the config (or inside a dotfiles repo it links to).
        let url = makeConfig(#"{"automation":{"portBase":9100}}"#)
        let outcome = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { nil },
            saveSecret: { _ in },
            backupTimestamp: "T"
        )
        #expect(outcome == .noPlaintextKey)
        #expect(!FileManager.default.fileExists(atPath: url.path + ".cmux-write.lock"))
    }

    @Test func leavesKeyForNextLaunchWhileAnotherWriterHoldsLock() async throws {
        // Launch must not wait on another writer, so the scrub skips and retries
        // on a later launch.
        let original = #"{"automation":{"socketPassword":"secret","portBase":9100}}"#
        let url = makeConfig(original)
        let held = try await JSONConfigWriteLock.acquire(target: url)
        defer { held.release() }
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
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
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

    // The scrub must remove only the secret's text, like the Settings write path,
    // instead of reserializing the user's file (#15656).

    @Test func keepsCommentsWhenScrubbing() throws {
        let url = makeConfig("""
        {
          // keep this comment
          "automation": {
            "socketPassword": "secret",
            "portBase": 9100
          }
        }
        """)
        let outcome = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { nil },
            saveSecret: { _ in },
            backupTimestamp: "T"
        )
        #expect(outcome == .migratedAndScrubbed)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("// keep this comment"))
        #expect(!text.contains("socketPassword"))
    }

    @Test func doesNotEscapeSlashesWhenScrubbing() throws {
        let url = makeConfig("""
        {
          "defaultWorkspacePath": "/Users/me/code",
          "automation": {
            "socketPassword": "secret",
            "portBase": 9100
          }
        }
        """)
        let outcome = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { nil },
            saveSecret: { _ in },
            backupTimestamp: "T"
        )
        #expect(outcome == .migratedAndScrubbed)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#""/Users/me/code""#))
        #expect(!text.contains(#"\/"#))
    }

    @Test func leavesRestOfFileUnchangedWhenScrubbing() throws {
        let url = makeConfig("""
        {
            "zoom": 1.5,
          "automation": {
            "portBase": 9100,
            "socketPassword": "secret"
          },
          "greeting": "line\\nnext caf\\u00e9",
          "alpha":   true
        }
        """)
        let outcome = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { nil },
            saveSecret: { _ in },
            backupTimestamp: "T"
        )
        #expect(outcome == .migratedAndScrubbed)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == """
        {
            "zoom": 1.5,
          "automation": {
            "portBase": 9100
          },
          "greeting": "line\\nnext caf\\u00e9",
          "alpha":   true
        }
        """)
    }

    @Test func keepsSymlinkedConfigWhenScrubbing() throws {
        let fileManager = FileManager.default
        let dotfiles = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-secret-migration-dotfiles-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("cmux.json", isDirectory: false)
        try Data(#"{"automation":{"socketPassword":"secret","portBase":9100}}"#.utf8).write(to: target)
        let url = makeConfig(nil)
        try fileManager.createSymbolicLink(at: url, withDestinationURL: target)

        let outcome = PlaintextSecretMigration.scrub(
            plaintextKeyPath: keyPath,
            configURL: url,
            loadCurrentSecret: { nil },
            saveSecret: { _ in },
            backupTimestamp: "T"
        )
        #expect(outcome == .migratedAndScrubbed)
        #expect((try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == target.path)
        let automation = try #require(object(at: target)?["automation"] as? [String: Any])
        #expect(automation["socketPassword"] == nil)
        #expect(automation["portBase"] as? Int == 9100)

        // The backup is a copy of the target's original contents beside cmux.json,
        // not a second link to the file that was just scrubbed.
        let backup = url.deletingPathExtension().appendingPathExtension("T.bak")
        #expect((try? fileManager.destinationOfSymbolicLink(atPath: backup.path)) == nil)
        let backedUp = try #require(object(at: backup)?["automation"] as? [String: Any])
        #expect(backedUp["socketPassword"] as? String == "secret")
    }
}
