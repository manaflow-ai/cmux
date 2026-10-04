import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite
struct ClaudeTranscriptForkSeederTests {
    @Test
    func copiesTranscriptAndRepairsMissingSidecar() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-seeder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let sessionID = "seed-session"
        let encodedSource = ClaudeProjectSlug().slug(forWorkingDirectory: source.path)
        let encodedDestination = ClaudeProjectSlug().slug(forWorkingDirectory: destination.path)
        let sourceProject = config.appendingPathComponent("projects").appendingPathComponent(encodedSource)
        try FileManager.default.createDirectory(at: sourceProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceTranscript = sourceProject.appendingPathComponent("\(sessionID).jsonl")
        try Data("{\"type\":\"user\"}\n".utf8).write(to: sourceTranscript)
        let sourceSidecar = sourceProject.appendingPathComponent(sessionID)
        try FileManager.default.createDirectory(at: sourceSidecar, withIntermediateDirectories: true)
        try Data("{\"state\":\"fixture\"}".utf8)
            .write(to: sourceSidecar.appendingPathComponent("state.json"))

        let request = ClaudeTranscriptForkSeedRequest(
            sessionID: sessionID,
            sourceWorkingDirectory: source.path,
            targetWorkingDirectory: destination.path,
            configDirectory: config.path
        )
        try await ClaudeTranscriptForkSeeder().seed(request)
        let targetProject = config.appendingPathComponent("projects").appendingPathComponent(encodedDestination)
        let targetTranscript = targetProject.appendingPathComponent("\(sessionID).jsonl")
        let targetSidecarFile = targetProject.appendingPathComponent(sessionID).appendingPathComponent("state.json")
        let copiedTranscript = try Data(contentsOf: targetTranscript)
        let sourceTranscriptData = try Data(contentsOf: sourceTranscript)
        let copiedSidecar = try Data(contentsOf: targetSidecarFile)
        let sourceSidecarData = try Data(contentsOf: sourceSidecar.appendingPathComponent("state.json"))
        #expect(copiedTranscript == sourceTranscriptData)
        #expect(copiedSidecar == sourceSidecarData)

        try FileManager.default.removeItem(at: targetProject.appendingPathComponent(sessionID))
        try await ClaudeTranscriptForkSeeder().seed(request)
        #expect(FileManager.default.fileExists(atPath: targetSidecarFile.path))
    }
}

extension ClaudeTranscriptForkSeederTests {
    @Test
    func copiesFromFallbackConfigDirectoryIntoLaunchConfig() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-seeder-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceConfig = root.appendingPathComponent("source-config")
        let launchConfig = root.appendingPathComponent("launch-config")
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let sessionID = "fallback-session"
        let sourceProject = sourceConfig.appendingPathComponent("projects")
            .appendingPathComponent(ClaudeProjectSlug().slug(forWorkingDirectory: source.path))
        try FileManager.default.createDirectory(at: sourceProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceTranscript = sourceProject.appendingPathComponent("\(sessionID).jsonl")
        try Data("{\"type\":\"user\"}\n".utf8).write(to: sourceTranscript)

        try await ClaudeTranscriptForkSeeder().seed(ClaudeTranscriptForkSeedRequest(
            sessionID: sessionID,
            sourceWorkingDirectory: source.path,
            targetWorkingDirectory: destination.path,
            configDirectory: launchConfig.path,
            sourceConfigDirectories: [sourceConfig.path]
        ))

        let targetTranscript = launchConfig.appendingPathComponent("projects")
            .appendingPathComponent(ClaudeProjectSlug().slug(forWorkingDirectory: destination.path))
            .appendingPathComponent("\(sessionID).jsonl")
        #expect(try Data(contentsOf: targetTranscript) == Data(contentsOf: sourceTranscript))
    }

    @Test
    func findsNestedTranscriptWithClaudeSlugAndRejectsDirectoryCandidate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-seeder-nested-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        let source = root.appendingPathComponent("source folder/é")
        let destination = root.appendingPathComponent("destination folder/é")
        let sessionID = "nested-session"
        let sourceProject = config.appendingPathComponent("projects")
            .appendingPathComponent(ClaudeProjectSlug().slug(forWorkingDirectory: source.path))
        let nestedDirectory = sourceProject.appendingPathComponent(sessionID).appendingPathComponent("messages")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sourceProject.appendingPathComponent("\(sessionID).jsonl"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceTranscript = nestedDirectory.appendingPathComponent("\(sessionID).jsonl")
        try Data("{\"type\":\"nested\"}\n".utf8).write(to: sourceTranscript)

        try await ClaudeTranscriptForkSeeder().seed(ClaudeTranscriptForkSeedRequest(
            sessionID: sessionID,
            sourceWorkingDirectory: source.path,
            targetWorkingDirectory: destination.path,
            configDirectory: config.path
        ))

        let targetTranscript = config.appendingPathComponent("projects")
            .appendingPathComponent(ClaudeProjectSlug().slug(forWorkingDirectory: destination.path))
            .appendingPathComponent(sessionID).appendingPathComponent("messages/\(sessionID).jsonl")
        let copied = try Data(contentsOf: targetTranscript)
        let sourceData = try Data(contentsOf: sourceTranscript)
        #expect(copied == sourceData)
    }
}
