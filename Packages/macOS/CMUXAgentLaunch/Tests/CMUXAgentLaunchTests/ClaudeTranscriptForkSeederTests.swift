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
        let encodedSource = source.path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let encodedDestination = destination.path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
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
