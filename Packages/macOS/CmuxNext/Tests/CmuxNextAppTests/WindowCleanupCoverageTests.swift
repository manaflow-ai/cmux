import Foundation
import Testing

/// Leo, 2026-10-28, on suites that leave windows open for later suites: "But why do you guys not
/// just clean up after yourselves, or at least do your best to?" A test file that opens a window
/// (`NSWindow(`, `NSPanel(`, a window or panel class's `(contentRect:`, `orderFront(`,
/// `makeKeyAndOrderFront(`) puts `.closesItsWindows` on each top-level suite that holds its tests,
/// so the suite closes and fails on what it leaves open (CmuxNextTestSupport/WindowLeakCheck.swift).
/// Comments and string literals are ignored. The census at the test process's exit names a suite
/// that opens windows some other way.
@Suite
struct WindowCleanupCoverageTests {
    static let trait = ".closesItsWindows"

    /// The package's `Tests`, from this file's path.
    static var tests: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func everySuiteThatOpensAWindowClosesWhatItLeaves() throws {
        let root = Self.tests.standardizedFileURL.path
        let enumerator = try #require(FileManager.default.enumerator(atPath: root))
        var scanned = 0
        var offenders: [String] = []
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".swift"), !relative.hasPrefix("Support/"), !relative.hasPrefix("CmuxNextTestSupport/")
            else { continue }
            let text = try String(contentsOfFile: root + "/" + relative, encoding: .utf8)
            scanned += 1
            offenders += Self.uncheckedSuites(in: text).map { "\(relative):\($0.line): \($0.name)" }
        }
        #expect(scanned > 1000, "found only \(scanned) Swift files under \(root)")
        #expect(offenders.isEmpty, """
        These suites open windows without `\(Self.trait)`. Add `@Suite(\(Self.trait))` to the \
        top-level suite (import CmuxNextTestSupport) and close each window in the test's own teardown:
        \(offenders.joined(separator: "\n"))
        """)
    }

    @Test func theScanFindsTopLevelSuitesWithTestsInFilesThatOpenWindows() {
        let opens = """
        import AppKit
        // NSWindow( in a comment does not count
        @MainActor @Suite(.serialized) struct Checked {
            @Test func a() { let w = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true); _ = w }
        }
        @Suite(.closesItsWindows) struct Fine { @Test func b() {} }
        @MainActor
        @Suite(
            .serialized,
            .closesItsWindows
        )
        struct FineMultiline { @Test func c() {} }
        struct Helper { func make() -> Int { 1 } }
        final class Missing {
            struct Nested { @Test func d() {} }
        }
        """
        #expect(Self.uncheckedSuites(in: opens).map(\.name) == ["Checked", "Missing"])
        let quiet = """
        let s = "NSWindow("
        /* panel.orderFront(nil) */
        struct NoWindows { @Test func e() {} }
        """
        #expect(Self.uncheckedSuites(in: quiet).isEmpty)
    }

    // MARK: Scanner

    struct Suite: Equatable {
        let line: Int
        let name: String
    }

    static let opensWindow = try? NSRegularExpression(
        pattern: #"\bNS(?:Window|Panel)\s*\(|\w(?:Window|Panel)\s*\(\s*contentRect\s*:|\.orderFront(?:Regardless)?\s*\(|\bmakeKeyAndOrderFront\s*\("#
    )
    static let declaration = try? NSRegularExpression(
        // Attribute arguments can contain nested calls, such as `.timeLimit(.minutes(2))`.
        // A declaration is either one line (consume its complete attribute argument) or a
        // continuation line after a multiline attribute, which `attributes(above:in:)` handles.
        pattern: #"^\s*(?:@\w+(?:\([^\n]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final|nonisolated)\s+)*(?:struct|class|enum|actor)\s+(\w+)"#
    )

    /// The top-level types in `text` that hold `@Test`s and lack the trait, when `text` opens a
    /// window; with 1-based declaration lines.
    static func uncheckedSuites(in text: String) -> [Suite] {
        let code = codeOnly(text)
        let whole = NSRange(code.startIndex..., in: code)
        guard let opensWindow, let declaration,
              opensWindow.firstMatch(in: code, range: whole) != nil else { return [] }
        let lines = code.components(separatedBy: "\n")
        var found: [Suite] = []
        var depth = 0
        var current: (line: Int, name: String)?
        var opened = false
        var hasTest = false
        for (index, line) in lines.enumerated() {
            if depth == 0, current == nil,
               let match = declaration.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let name = Range(match.range(at: 1), in: line) {
                current = (index, String(line[name]))
                opened = false
                hasTest = false
            }
            if current != nil, line.contains("@Test") { hasTest = true }
            for character in line {
                if character == "{" {
                    depth += 1
                    if current != nil { opened = true }
                } else if character == "}" {
                    depth -= 1
                    if let suite = current, opened, depth == 0 {
                        if hasTest, !attributes(above: suite.line, in: lines).contains(trait) {
                            found.append(Suite(line: suite.line + 1, name: suite.name))
                        }
                        current = nil
                    }
                }
            }
        }
        return found
    }

    /// The declaration line and the attribute lines directly above it.
    static func attributes(above line: Int, in lines: [String]) -> String {
        var start = line
        while start > 0 {
            let previous = lines[start - 1].trimmingCharacters(in: .whitespaces)
            guard previous.hasPrefix("@") || previous.hasPrefix(")") || previous.hasPrefix(".") else { break }
            start -= 1
        }
        return lines[start...line].joined(separator: "\n")
    }

    /// `text` with comments removed and string contents blanked, line count kept.
    static func codeOnly(_ text: String) -> String {
        var out = ""
        var iterator = Array(text)[...]
        var inBlock = false
        var inString = false
        var inMultiline = false
        while let character = iterator.first {
            iterator = iterator.dropFirst()
            let next = iterator.first
            let opensTriple = character == "\"" && iterator.prefix(2).elementsEqual("\"\"")
            if inMultiline {
                if character == "\n" {
                    out.append("\n")
                } else if character == "\\" {
                    iterator = iterator.dropFirst()
                } else if opensTriple {
                    inMultiline = false
                    iterator = iterator.dropFirst(2)
                    out.append("\"\"\"")
                }
            } else if character == "\n" {
                out.append("\n")
                inString = false
            } else if !inBlock, !inString, opensTriple {
                inMultiline = true
                iterator = iterator.dropFirst(2)
                out.append("\"\"\"")
            } else if inBlock {
                if character == "*", next == "/" { inBlock = false; iterator = iterator.dropFirst() }
            } else if inString {
                if character == "\\" { iterator = iterator.dropFirst() } else if character == "\"" { inString = false; out.append("\"") }
            } else if character == "/", next == "/" {
                while let skipped = iterator.first, skipped != "\n" { iterator = iterator.dropFirst() }
            } else if character == "/", next == "*" {
                inBlock = true
                iterator = iterator.dropFirst()
            } else if character == "\"" {
                inString = true
                out.append("\"")
            } else {
                out.append(character)
            }
        }
        return out
    }
}
