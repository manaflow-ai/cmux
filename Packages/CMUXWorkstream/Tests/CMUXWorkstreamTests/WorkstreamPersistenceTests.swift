import Foundation
import Testing
@testable import CMUXWorkstream

@Suite("WorkstreamPersistence")
struct WorkstreamPersistenceTests {
    @Test("Append + loadRecent round-trips items oldest-first")
    func appendAndLoad() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        let items = (0..<5).map { i in
            WorkstreamItem(
                workstreamId: "s\(i)",
                source: .claude,
                kind: .permissionRequest,
                payload: .permissionRequest(
                    requestId: "r\(i)",
                    toolName: "Write",
                    toolInputJSON: "{}",
                    pattern: nil
                )
            )
        }
        for item in items {
            try await persistence.append(item)
        }
        let loaded = try await persistence.loadRecent(limit: 10)
        #expect(loaded.count == 5)
        #expect(loaded.first?.workstreamId == "s0")
        #expect(loaded.last?.workstreamId == "s4")
    }

    @Test("loadRecent with limit returns the most recent suffix")
    func loadRecentLimit() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        for i in 0..<5 {
            try await persistence.append(WorkstreamItem(
                workstreamId: "s\(i)",
                source: .claude,
                kind: .permissionRequest,
                payload: .permissionRequest(requestId: "r\(i)", toolName: "t", toolInputJSON: "{}", pattern: nil)
            ))
        }
        let loaded = try await persistence.loadRecent(limit: 2)
        #expect(loaded.count == 2)
        #expect(loaded.first?.workstreamId == "s3")
        #expect(loaded.last?.workstreamId == "s4")
    }

    @Test("append redacts sensitive tool input before writing JSONL")
    func appendRedactsSensitiveToolInput() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-redact-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        try await persistence.append(WorkstreamItem(
            workstreamId: "s",
            source: .claude,
            kind: .permissionRequest,
            payload: .permissionRequest(
                requestId: "r",
                toolName: "Bash",
                toolInputJSON: #"{"command":"OPENAI_API_KEY=sk-test node \#(homePath)/app.js","env":{"SECRET":"value"}}"#,
                pattern: nil
            )
        ))

        let loaded = try await persistence.loadRecent(limit: 1)
        guard case .permissionRequest(_, _, let toolInputJSON, _) = loaded[0].payload else {
            Issue.record("expected permission payload")
            return
        }
        #expect(!toolInputJSON.contains("sk-test"))
        #expect(!toolInputJSON.contains(#""value""#))
        #expect(toolInputJSON.contains("<redacted>"))
        let data = try #require(toolInputJSON.data(using: .utf8))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect((object["command"] as? String)?.contains("~/app.js") == true)
    }

    @Test("Missing file returns empty")
    func missingFileEmpty() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-missing-\(UUID().uuidString).jsonl")
        let persistence = WorkstreamPersistence(fileURL: tmp)
        let loaded = try await persistence.loadRecent(limit: 10)
        #expect(loaded.isEmpty)
    }

    @Test("Non-positive limit returns empty")
    func nonPositiveLimitEmpty() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-limit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "s", source: .claude, kind: .sessionStart, payload: .sessionStart
        ))
        let loaded = try await persistence.loadRecent(limit: 0)
        #expect(loaded.isEmpty)
    }

    @Test("clear removes the backing file")
    func clearRemovesFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-clear-\(UUID().uuidString).jsonl")
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "s", source: .claude, kind: .sessionStart, payload: .sessionStart
        ))
        #expect(FileManager.default.fileExists(atPath: tmp.path))
        try await persistence.clear()
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
    }
}
