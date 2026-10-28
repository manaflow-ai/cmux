import Foundation
import Testing

/// The terminal client is called from the main actor, from Cloud lifecycle
/// tasks and from the native library's output threads at once, so the state
/// those threads share must be checked by the compiler. `@unchecked Sendable`
/// switches that check off for a whole type: the client's state class kept
/// nine mutable fields behind a hand-held `NSCondition`, and nothing but
/// review kept a new field under the lock.
///
/// Mutable state lives in a `Mutex` (CmuxSafeConcurrency), where it is reached
/// only inside `withLock`, and the types that hold it are checked `Sendable`.
/// An `@unchecked Sendable` may only wrap state that never changes (a native
/// handle), and it says why that is safe on its line or the line above with
/// `// crash-allow:`, as the cmux-next guardrails ask.
@Suite struct TerminalClientSendabilityTests {
    @Test func uncheckedSendableOnlyWrapsImmutableArguedState() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxTerminalClientKit")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains("@unchecked Sendable") || line.contains("nonisolated(unsafe)") {
                let place = "\(file.lastPathComponent):\(index + 1)"
                let above = index > 0 ? lines[index - 1] : ""
                let argued = [line, above].contains { text in
                    guard let range = text.range(of: "// crash-allow:") else { return false }
                    return !text[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
                }
                if !argued { offenders.append("\(place) has no crash-allow reason") }
                if line.contains("nonisolated(unsafe)") { continue }
                for stored in Self.mutableStoredProperties(of: lines, declaredAt: index) {
                    offenders.append("\(place) is unchecked over mutable `\(stored)`")
                }
            }
        }
        #expect(offenders.isEmpty, "unchecked sendability in CmuxTerminalClientKit: \(offenders.sorted())")
    }

    /// The `var` stored properties declared directly in the body of the type
    /// declared on `lines[start]`. A `var` followed by `{` on its line is
    /// computed and not counted.
    private static func mutableStoredProperties(of lines: [String], declaredAt start: Int) -> [String] {
        var depth = 0
        var opened = false
        var found: [String] = []
        for line in lines[start...] {
            let code = line.components(separatedBy: "//")[0]
            if opened, depth == 1 {
                let words = code.split(whereSeparator: \.isWhitespace).map(String.init)
                if let varIndex = words.firstIndex(of: "var"),
                   words[..<varIndex].allSatisfy({ Self.declarationModifiers.contains($0) }),
                   !code.contains("{")
                {
                    found.append(code.trimmingCharacters(in: .whitespaces))
                }
            }
            for character in code {
                if character == "{" {
                    depth += 1
                    opened = true
                } else if character == "}" {
                    depth -= 1
                }
            }
            if opened, depth <= 0 { break }
        }
        return found
    }

    private static let declarationModifiers: Set<String> = [
        "private", "fileprivate", "internal", "public", "package", "weak", "unowned", "lazy",
        "private(set)", "fileprivate(set)", "internal(set)", "public(set)", "package(set)",
    ]
}
