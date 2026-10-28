import Foundation
import Testing

/// `MainActor.assumeIsolated` turns the compiler's isolation check into a
/// runtime trap: if the closure ever runs off the main thread, the app
/// crashes (or, in a build without the check, races main-actor state). Each
/// call in CmuxConversationGeometry must therefore name the thread guarantee
/// it relies on in a `// main-proof:` comment, as the cmux-next guardrails
/// (`scripts/cmux-next/arch_counts.py`, `crash_ratchet.py`) ask: on the call's
/// line, in the comment lines directly above it, or trailing the opener line
/// directly above (finding strict-5: the screen-effect and pop-effect
/// transaction completions had no proof).
///
/// Reads the sources: the check is about the written proof, which no runtime
/// test can see.
@Suite struct ConversationGeometryMainProofTests {
    @Test func assumeIsolatedCallsStateTheirMainThreadProof() throws {
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
                guard code.contains("assumeIsolated") else { continue }
                if !Self.isProved(lines, index) { offenders.append("\(file.lastPathComponent):\(index + 1)") }
            }
        }
        #expect(offenders.isEmpty, "MainActor.assumeIsolated without a main-proof in CmuxConversationGeometry: \(offenders.sorted())")
    }

    /// The same placement rule as `arch_counts.py`'s `_is_proved`.
    private static func isProved(_ lines: [String], _ index: Int) -> Bool {
        func hasProof(_ text: String) -> Bool {
            guard let range = text.range(of: "main-proof:") else { return false }
            return !text[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
        }
        if hasProof(lines[index]) { return true }
        var above = index - 1
        while above >= 0 {
            let trimmed = lines[above].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") else { break }
            if hasProof(lines[above]) { return true }
            above -= 1
        }
        return above == index - 1 && above >= 0 && hasProof(lines[above]) && !lines[above].contains("assumeIsolated")
    }
}
