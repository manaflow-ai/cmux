import Foundation
import Testing

/// The iOS transcript measures rows away from the main thread
/// (`MessageLayoutCache.measure` in a detached task) while the main thread
/// configures cells and reacts to trait changes, so state the two share must
/// be checked by the compiler. `nonisolated(unsafe)` switches that check off:
/// `ConversationTheme.displayScale` was written on the main thread on a
/// display scale change while a measuring task read it, and the font cache
/// relied on a runtime main-thread test alone.
///
/// Main-thread state is `@MainActor`; what a measuring task needs comes from
/// the traits it runs in (`performAsCurrent`). A declaration that is truly
/// safe says why on its line or the line above with `// crash-allow:`, as
/// the cmux-next guardrails ask.
///
/// The iOS views can't run under `swift test`, so this reads their sources.
@Suite struct ConversationUISharedStateTests {
    @Test func uiSourcesShareNoUncheckedMutableState() throws {
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
            for (index, line) in lines.enumerated() where line.contains("nonisolated(unsafe)") {
                let above = index > 0 ? lines[index - 1] : ""
                let argued = [line, above].contains { text in
                    guard let range = text.range(of: "// crash-allow:") else { return false }
                    return !text[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
                }
                if !argued { offenders.append("\(file.lastPathComponent):\(index + 1)") }
            }
        }
        #expect(offenders.isEmpty, "nonisolated(unsafe) without a safety argument in CmuxConversationUI: \(offenders.sorted())")
    }
}
