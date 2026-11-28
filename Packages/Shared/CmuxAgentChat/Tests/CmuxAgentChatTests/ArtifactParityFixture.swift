import Foundation
import Testing

@testable import CmuxAgentChat

struct ArtifactParityFixture {
    enum Agent: String {
        case claude
        case codex
    }

    let agent: Agent
    let lines: [String]
    let parseResult: ChatTranscriptParseResult
    let workingDirectory: String
    let artifacts: [ChatArtifactIndexedReference]

    static func load(_ agent: Agent) throws -> ArtifactParityFixture {
        let name = "\(agent.rawValue)-adversarial"
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "jsonl"
            )
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parseResult: ChatTranscriptParseResult
        switch agent {
        case .claude:
            parseResult = ClaudeTranscriptParser().parse(lines: lines, startingSeq: 0)
        case .codex:
            parseResult = CodexTranscriptParser().parse(lines: lines, startingSeq: 0)
        }
        let cwd = "/Users/test/project"
        let artifacts = ChatArtifactIndexedReference.derive(
            from: parseResult.messages,
            supplementalReferences: parseResult.artifactReferences,
            workingDirectory: cwd
        )
        return ArtifactParityFixture(
            agent: agent,
            lines: lines,
            parseResult: parseResult,
            workingDirectory: cwd,
            artifacts: artifacts
        )
    }

    func artifact(path: String) -> ChatArtifactIndexedReference? {
        artifacts.first { $0.path == path }
    }
}
