@testable import CmuxChief
import Foundation
import Testing

/// Chief's file-backed memory: defaults, add/list/forget, rendering and the
/// on-disk format the `cmux chief memory` CLI shares.
@Suite struct ChiefMemoryTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return "m-" + String(format: "%08x", value)
        }
    }

    func makeMemory(clock: Date = Date(timeIntervalSince1970: 1_792_000_000)) -> (ChiefMemory, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-memory-\(UUID().uuidString)", isDirectory: true)
        let counter = Counter()
        let memory = ChiefMemory(paths: ChiefMemoryPaths(home: ChiefHome(root: root)),
                                 now: { clock },
                                 makeID: { counter.next() })
        return (memory, root)
    }

    @Test func pathsLiveInTheHomeMemoryDirectory() {
        let home = ChiefHome(root: URL(fileURLWithPath: "/tmp/chief-x", isDirectory: true))
        let paths = ChiefMemoryPaths(home: home)
        #expect(paths.directory.path == "/tmp/chief-x/memory")
        #expect(paths.person.lastPathComponent == "person.md")
        #expect(paths.instructions.lastPathComponent == "instructions.md")
        #expect(paths.facts.lastPathComponent == "memory.jsonl")
    }

    @Test func defaultsAreWrittenOnceAndNeverOverwriteEdits() throws {
        let (memory, root) = makeMemory()
        defer { try? FileManager.default.removeItem(at: root) }
        try memory.ensureDefaults()
        let person = try String(contentsOf: memory.paths.person, encoding: .utf8)
        #expect(person.contains("Act without asking"))
        try "I am Ada.".write(to: memory.paths.person, atomically: true, encoding: .utf8)
        try memory.ensureDefaults()
        #expect(try String(contentsOf: memory.paths.person, encoding: .utf8) == "I am Ada.")
        // The instructions template is only a comment, so the prompt sees nothing.
        #expect(memory.snapshot().instructions.isEmpty)
        #expect(memory.snapshot().person == "I am Ada.")
    }

    @Test func addListForgetRoundTrip() throws {
        let (memory, root) = makeMemory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try memory.add("  Their main repo is\n~/code/app  ", source: "cli")
        let second = try memory.add("Prefers Codex for backend work", source: "app")
        #expect(first.text == "Their main repo is ~/code/app")
        #expect(memory.facts().map(\.id) == [first.id, second.id])
        #expect(memory.facts().first == first)

        let removed = try memory.forget(first.id)
        #expect(removed == first)
        #expect(memory.facts() == [second])
        #expect(throws: ChiefMemoryError.notFound(id: "m-nope")) { try memory.forget("m-nope") }
    }

    @Test func updateKeepsIdentityAndMetadata() throws {
        let (memory, root) = makeMemory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try memory.add("Prefers the dark theme", source: "app")
        let updated = try memory.update(original.id, text: "Prefers the light theme")
        #expect(updated.id == original.id)
        #expect(updated.source == original.source)
        #expect(updated.createdAt == original.createdAt)
        #expect(updated.text == "Prefers the light theme")
        #expect(memory.facts() == [updated])
    }

    @Test func refusesEmptyLongAndSecretText() throws {
        let (memory, root) = makeMemory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ChiefMemoryError.emptyText) { try memory.add(" \n ", source: "cli") }
        #expect(throws: ChiefMemoryError.textTooLong(limit: ChiefMemory.maxFactBytes)) {
            try memory.add(String(repeating: "a", count: ChiefMemory.maxFactBytes + 1), source: "cli")
        }
        #expect(throws: ChiefMemoryError.looksLikeSecret) {
            try memory.add("token is " + "ghp" + "_" + "abcdefghijklmnopqrstuvwxyz0123456789", source: "cli")
        }
        #expect(throws: ChiefMemoryError.looksLikeSecret) {
            try memory.add("db is postgres://admin:hunter22@db.internal/app", source: "cli")
        }
        #expect(memory.facts().isEmpty)
        #expect(!ChiefMemory.looksLikeSecret("Uses the password manager for shared logins"))
    }

    /// Secrets the earlier filter let through (PR 21063 review), plus the ones it caught.
    static let secrets: [String] = [
        "AWS_SECRET_ACCESS_KEY=" + "fixture/fixture/fixture/fixture000000",
        "export GITHUB_TOKEN=abcdef1234567890",
        "MY_API_KEY=abcdef123456",
        "my-api-key: abcdef123456",
        "DB_PASSWORD=\"hunter2hunter2\"",
        "STRIPE_PRIVATE_KEY = abcdef123456",
        "aws access_key: AKIAIOSFODNN7EXAMPLE",
        "stripe key " + "sk_" + "live_" + "0000fixture0000fixture00",
        "test key " + "rk_" + "test_" + "0000fixture0000fixture00",
        "npm" + "_" + "abcdefghijklmnopqrstuvwxyz0123456789",
        "gitlab " + "glp" + "at-" + "abcdefghij0123456789",
        "token " + "ghp" + "_" + "abcdefghijklmnopqrstuvwxyz0123456789",
        "GITHUB_TOKEN_" + "ghp" + "_" + "abcdefghijklmnopqrstuv",
        "slack " + "xox" + "b-" + "1234567890-abcdefghij",
        "key AKIAIOSFODNN7EXAMPLE",
        "KEY_AKIAIOSFODNN7EXAMPLE",
        "temporary ASIAIOSFODNN7EXAMPLE",
        "-----BEGIN OPENSSH PRIVATE KEY----- b3BlbnNzaC1rZXk",
        "-----BEGIN RSA PRIVATE KEY-----",
        "-----BEGIN PRIVATE KEY-----",
        "-----BEGIN PGP PRIVATE KEY BLOCK-----",
        "sk-proj-abcdefghijklmnopqrstuvwxyz",
        "db is postgres://admin:hunter22@db.internal/app",
    ]

    static let notSecrets: [String] = [
        "Uses the password manager for shared logins",
        "Rotates tokens every month",
        "Prefers API keys stored in 1Password",
        "Machine brave-otter is for builds",
        "Secrets live in the team vault",
    ]

    @Test(arguments: secrets)
    func catchesSecret(text: String) {
        #expect(ChiefMemory.looksLikeSecret(text), "\(text)")
    }

    @Test(arguments: notSecrets)
    func keepsOrdinaryFacts(text: String) {
        #expect(!ChiefMemory.looksLikeSecret(text), "\(text)")
    }

    @Test func onDiskLineMatchesTheSharedFormat() throws {
        let (memory, root) = makeMemory()
        defer { try? FileManager.default.removeItem(at: root) }
        try memory.add("Machine brave-otter is for builds", source: "cli")
        let text = try String(contentsOf: memory.paths.facts, encoding: .utf8)
        #expect(text == #"{"createdAt":"2026-10-14T17:46:40Z","id":"m-00000001","source":"cli","text":"Machine brave-otter is for builds"}"# + "\n")
    }

    @Test func tornAndForeignLinesAreSkipped() throws {
        let (memory, root) = makeMemory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fact = try memory.add("Keeps notes in ~/notes", source: "cli")
        let handle = try FileHandle(forWritingTo: memory.paths.facts)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"m-torn","te"#.utf8))
        try handle.close()
        #expect(memory.facts() == [fact])
    }

    @Test func renderIsNewestFirstAndCapped() {
        let facts = (0..<10).map { index in
            ChiefMemoryFact(id: "m-\(index)", text: "fact number \(index)",
                            createdAt: Date(timeIntervalSince1970: 1_792_000_000 + Double(index)), source: "cli")
        }
        let full = ChiefMemory.render(facts: facts)
        #expect(full.hasPrefix("- fact number 9 (m-9, 2026-10-14)"))
        #expect(full.components(separatedBy: "\n").count == 10)

        let lineBytes = "- fact number 9 (m-9, 2026-10-14)\n".utf8.count
        let capped = ChiefMemory.render(facts: facts, capBytes: lineBytes * 3)
        let lines = capped.components(separatedBy: "\n")
        #expect(Array(lines.prefix(3)) == ["- fact number 9 (m-9, 2026-10-14)", "- fact number 8 (m-8, 2026-10-14)", "- fact number 7 (m-7, 2026-10-14)"])
        #expect(lines.last?.contains("7 older facts not shown") == true)
        #expect(ChiefMemory.render(facts: []).isEmpty)
    }

    @Test func concurrentWritersLoseNothing() async throws {
        let (memory, root) = makeMemory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ChiefMemory(paths: memory.paths)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask { _ = try? writer.add("fact \(index)", source: "cli") }
            }
        }
        #expect(writer.facts().count == 40)
        #expect(Set(writer.facts().map(\.id)).count == 40)
    }
}
