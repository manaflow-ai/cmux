import CMUXAgentLaunch
import Foundation
import Testing

@Suite("ClaudeTranscriptConversationLocator")
struct ClaudeTranscriptConversationLocatorTests {
    private let sessionID = "0b0e8a52-1111-4222-8333-944455556666"
    private let workingDirectory = "/tmp/priority-locator-project"

    private func withConfigDirectory(_ body: (String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(root)
    }

    private func writeTranscript(_ contents: String, configDirectory: String) throws {
        let project = configDirectory + "/projects/"
            + ClaudeProjectSlug().slug(forWorkingDirectory: workingDirectory)
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try contents.write(toFile: project + "/\(sessionID).jsonl", atomically: true, encoding: .utf8)
    }

    private func has(_ id: String, _ config: String) throws -> Bool {
        try ClaudeTranscriptConversationLocator.hasConversation(
            sessionID: id, workingDirectory: workingDirectory, configDirectory: config
        )
    }

    @Test func findsAConversation() throws {
        try withConfigDirectory { config in
            try writeTranscript(#"{"type":"user","message":{"content":"hi"}}"# + "\n", configDirectory: config)
            #expect(try has(sessionID, config))
        }
    }

    @Test func emptySessionIsNotAConversation() throws {
        try withConfigDirectory { config in
            try writeTranscript(#"{"type":"summary","summary":"x"}"# + "\n", configDirectory: config)
            #expect(try !has(sessionID, config))
        }
    }

    @Test func missingTranscriptIsFalse() throws {
        try withConfigDirectory { config in
            #expect(try !has(sessionID, config))
        }
    }

    @Test func rejectsAnUnsafeSessionID() throws {
        try withConfigDirectory { config in
            try writeTranscript(#"{"type":"user"}"# + "\n", configDirectory: config)
            #expect(try !has("../x", config))
        }
    }
}
