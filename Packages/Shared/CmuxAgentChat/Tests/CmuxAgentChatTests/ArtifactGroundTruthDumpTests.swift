import Foundation
import Testing
@testable import CmuxAgentChat

/// Diagnostic dump: runs the real parser + gallery derivation over one
/// transcript and prints `ARTIFACT_ITEM provenance|path` lines for external
/// cross-checking. A no-op unless `CMUX_ARTIFACT_DUMP` names a transcript
/// path (never runs in CI). Prints paths only, never transcript content.
struct ArtifactGroundTruthDumpTests {
    @Test("dump derived artifacts for one transcript")
    func dumpDerivedArtifacts() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_ARTIFACT_DUMP"], !path.isEmpty else { return }
        let cwd = env["CMUX_ARTIFACT_DUMP_CWD"]
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let messages: [ChatMessage]
        if (path as NSString).lastPathComponent.hasPrefix("rollout-") || path.contains("/.codex/") {
            messages = CodexTranscriptParser().parse(lines: lines, startingSeq: 0).messages
        } else {
            messages = ClaudeTranscriptParser().parse(lines: lines, startingSeq: 0).messages
        }
        let items = ChatArtifactIndexedReference.derive(from: messages, workingDirectory: cwd)
        print("ARTIFACT_DUMP_BEGIN \(path)")
        for item in items.sorted(by: { $0.path < $1.path }) {
            print("ARTIFACT_ITEM \(item.provenance.rawValue)|\(item.path)")
        }
        print("ARTIFACT_DUMP_END count=\(items.count)")
    }
}
