import Foundation
import Testing

/// CmuxConversationCore shares state across threads in three places that
/// were marked `@unchecked Sendable` with no written reason: the link-split
/// cache (row building runs on the main thread and in detached measuring
/// work), the simulator backend (called from any task, its state in an
/// actor) and the JSON box its requests and replies cross that actor in.
/// `@unchecked Sendable` switches the compiler's data-race check off for
/// everything a type carries.
///
/// Shared state sits in a `Mutex`, a type whose fields are all `Sendable`
/// is checked, and a type that is truly safe says why on its line or the
/// line above with `// crash-allow:`, as the cmux-next guardrails ask.
@Suite struct ConversationCoreSendableTests {
    @Test func uncheckedSendableTypesStateTheirSafetyArgument() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxConversationCore")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
                guard code.range(of: #"@unchecked\s+Sendable"#, options: .regularExpression) != nil else { continue }
                let above = index > 0 ? lines[index - 1] : ""
                let argued = [line, above].contains { text in
                    guard let range = text.range(of: "// crash-allow:") else { return false }
                    return !text[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
                }
                if !argued { offenders.append("\(file.lastPathComponent):\(index + 1)") }
            }
        }
        #expect(offenders.isEmpty, "@unchecked Sendable without a safety argument in CmuxConversationCore: \(offenders.sorted())")
    }
}
