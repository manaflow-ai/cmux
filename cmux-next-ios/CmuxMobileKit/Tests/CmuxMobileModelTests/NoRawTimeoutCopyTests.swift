import Foundation
import Testing

/// Detector for the class of copy Leo asked to never see again (2026-11-21: "i keep seeing "the
/// mac didnt answer in time" i dont want to see that"): no string in the iPhone app's sources says
/// the Mac (or anything) "didn't answer" or that a request "timed out". A slow or dropped
/// connection rides out the blip (`AcpmuxHub+Steady.swift`) and, past a generous bound, says what
/// to do (`LinkError.timeoutSentence`, `ConnectionInterrupted.message`). Timeout errors carry raw
/// diagnostics only, which `LinkError.errorDescription` never shows.
///
/// Comments are skipped: they may describe what happens. A test fixture may say it on purpose.
@Suite struct NoRawTimeoutCopyTests {
    static let banned = [
        "didn't answer", "didn\u{2019}t answer", "did not answer", "didnt answer",
        "timed out. Try", "didn't answer in time",
    ]

    /// `Sources/` of this package, from this file's path.
    static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// The parts of a line inside string literals (`"…"`), comments dropped.
    static func literals(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { return [] }
        var out: [String] = []
        var current: String?
        var escaped = false
        var previous: Character = " "
        for char in line {
            if var text = current {
                if escaped { escaped = false; text.append(char); current = text; continue }
                if char == "\\" { escaped = true; text.append(char); current = text; continue }
                if char == "\"" { out.append(text); current = nil; continue }
                text.append(char)
                current = text
            } else {
                if char == "/", previous == "/" { break }
                if char == "\"" { current = "" }
                previous = char
            }
        }
        if let current { out.append(current) }
        return out
    }

    @Test func noSourceSaysTheMacDidNotAnswer() throws {
        let root = Self.sources
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 100, "found the package's sources at \(root.path)")
        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for literal in Self.literals(in: String(line)) {
                    let lower = literal.lowercased()
                    if Self.banned.contains(where: { lower.contains($0.lowercased()) }) {
                        hits.append("\(file.path.replacingOccurrences(of: root.path + "/", with: "")):\(number + 1): \(literal)")
                    }
                }
            }
        }
        #expect(hits.isEmpty, "raw timeout copy in a normal path:\n\(hits.joined(separator: "\n"))")
    }

    @Test func theScannerReadsLiteralsNotComments() {
        #expect(Self.literals(in: #"    let a = "The Mac didn't answer." // said"#) == ["The Mac didn't answer."])
        #expect(Self.literals(in: #"    /// the Mac didn't answer"#).isEmpty)
        #expect(Self.literals(in: #"    x = f() // "didn't answer""#).isEmpty)
        #expect(Self.literals(in: #"    "a \"b\" c""#) == [#"a \"b\" c"#])
    }
}
