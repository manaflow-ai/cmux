import CMUXAgentLaunch
import Foundation
import Testing

@Suite("ClaudeTranscriptConversationLocator")
struct ClaudeTranscriptConversationLocatorTests {
    private let sessionID = "0b0e8a52-1111-4222-8333-944455556666"
    private let workingDirectory = "/tmp/priority-locator-project"
    private let conversation = #"{"type":"user","message":{"content":"hi"}}"# + "\n"

    private func withConfigDirectory(_ body: (String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(root)
    }

    private func projectDirectory(_ configDirectory: String) -> String {
        configDirectory + "/projects/" + ClaudeProjectSlug().slug(forWorkingDirectory: workingDirectory)
    }

    private func writeTranscript(_ contents: String, configDirectory: String, sessionID: String? = nil) throws {
        let project = projectDirectory(configDirectory)
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try contents.write(toFile: project + "/\(sessionID ?? self.sessionID).jsonl", atomically: true, encoding: .utf8)
    }

    private func has(_ id: String, _ config: String) throws -> Bool {
        try ClaudeTranscriptConversationLocator.hasConversation(
            sessionID: id, workingDirectory: workingDirectory, configDirectory: config
        )
    }

    @Test func findsAConversation() throws {
        try withConfigDirectory { config in
            try writeTranscript(conversation, configDirectory: config)
            let found = try has(sessionID, config)
            #expect(found)
        }
    }

    @Test func emptySessionIsNotAConversation() throws {
        try withConfigDirectory { config in
            try writeTranscript(#"{"type":"summary","summary":"x"}"# + "\n", configDirectory: config)
            let found = try has(sessionID, config)
            #expect(!found)
        }
    }

    @Test func missingTranscriptIsFalse() throws {
        try withConfigDirectory { config in
            let found = try has(sessionID, config)
            #expect(!found)
        }
    }

    /// A traversal id would reach `projects/x.jsonl`, which holds a conversation: only the id
    /// check keeps it from being read.
    @Test func rejectsATraversalSessionID() throws {
        try withConfigDirectory { config in
            try writeTranscript(conversation, configDirectory: config)
            try conversation.write(toFile: config + "/projects/x.jsonl", atomically: true, encoding: .utf8)
            let found = try has("../x", config)
            #expect(!found)
            #expect(ClaudeTranscriptConversationLocator.transcriptPath(
                sessionID: "../x", workingDirectory: workingDirectory, configDirectory: config
            ) == nil)
        }
    }

    /// Each id names a transcript that holds a conversation, so a `false` comes from the check.
    @Test(arguments: ["a b", "a\nb", ""])
    func rejectsAnUnsafeSessionID(_ unsafeID: String) throws {
        try withConfigDirectory { config in
            try writeTranscript(conversation, configDirectory: config, sessionID: unsafeID)
            let found = try has(unsafeID, config)
            #expect(!found)
            #expect(ClaudeTranscriptConversationLocator.transcriptPath(
                sessionID: unsafeID, workingDirectory: workingDirectory, configDirectory: config
            ) == nil)
        }
    }

    @Test func transcriptPathNamesTheSessionFile() throws {
        try withConfigDirectory { config in
            try writeTranscript(conversation, configDirectory: config)
            let path = ClaudeTranscriptConversationLocator.transcriptPath(
                sessionID: sessionID, workingDirectory: workingDirectory, configDirectory: config
            )
            #expect(path == projectDirectory(config) + "/\(sessionID).jsonl")
        }
    }
}
