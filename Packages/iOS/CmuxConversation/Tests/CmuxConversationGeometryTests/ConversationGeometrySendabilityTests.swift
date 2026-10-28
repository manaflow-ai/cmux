import Foundation
import Testing

/// The effect-glyph cache (`ConversationTextEffectLayer.renderings`) is read
/// and written by the main thread (`update`, `cachedRendering`) and by the
/// detached prefetch and render-ahead tasks (`prepare`). A
/// `nonisolated(unsafe)` declaration switches the compiler's data-race check
/// off for that state, so each one must say why it is still safe, on its
/// line or the line above, with `// crash-allow:` as the cmux-next guardrails
/// ask (finding strict-10: the cache had no argument).
///
/// Reads the sources: the check is about the written argument, which no
/// runtime test can see.
@Suite struct ConversationGeometrySendabilityTests {
    @Test func nonisolatedUnsafeDeclarationsStateTheirSafetyArgument() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxConversationGeometry")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
                guard code.contains("nonisolated(unsafe)") else { continue }
                let above = index > 0 ? lines[index - 1] : ""
                let argued = [line, above].contains { text in
                    guard let range = text.range(of: "// crash-allow:") else { return false }
                    return !text[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
                }
                if !argued { offenders.append("\(file.lastPathComponent):\(index + 1)") }
            }
        }
        #expect(offenders.isEmpty, "nonisolated(unsafe) without a safety argument in CmuxConversationGeometry: \(offenders.sorted())")
    }
}
