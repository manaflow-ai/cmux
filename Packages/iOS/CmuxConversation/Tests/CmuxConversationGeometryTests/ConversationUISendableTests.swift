import Foundation
import Testing

/// The iOS transcript builds and measures bubble text away from the main
/// thread (`MessageLayoutCache.measure` and the live-message preparation in
/// detached work) and shares it with the main thread through
/// `BubbleTextCache`; tapback art is recolored off the main thread too. A
/// type marked `@unchecked Sendable` switches the compiler's data-race check
/// off for everything it carries: row models, layouts, attributed strings
/// and a picked photo crossed threads in five such wrappers, and two caches
/// guarded their state with a bare `NSLock`, none with a written reason why
/// that was safe.
///
/// Values that cross are Sendable value types (or are sent once with
/// `sending`), shared state sits in a `Mutex`, and a type that is truly safe
/// says why on its line or the line above with `// crash-allow:`, as the
/// cmux-next guardrails ask.
///
/// The iOS views can't run under `swift test`, so this reads their sources.
@Suite struct ConversationUISendableTests {
    @Test func uncheckedSendableTypesStateTheirSafetyArgument() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxConversationUI")
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
        #expect(offenders.isEmpty, "@unchecked Sendable without a safety argument in CmuxConversationUI: \(offenders.sorted())")
    }
}
