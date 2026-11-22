import Foundation
import Testing

/// Leo, 2026-10-28, on suites that leave windows open for later suites: "But why do you guys not
/// just clean up after yourselves, or at least do your best to?" A test file that opens a window
/// (`NSWindow(`, `NSPanel(`, a window or panel class's `(contentRect:`, `orderFront(`,
/// `makeKeyAndOrderFront(`) puts `.closesItsWindows` on each top-level suite that holds its tests,
/// so the suite closes and fails on what it leaves open (CmuxNextTestSupport/WindowLeakCheck.swift).
/// Tests in a top-level `extension` of a type count as that type's: its declaration, in any test
/// file, carries the trait. Comments and string literals are ignored. The census at the test process's exit names a suite
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
        var files: [(path: String, text: String)] = []
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".swift"), !relative.hasPrefix("Support/"), !relative.hasPrefix("CmuxNextTestSupport/")
            else { continue }
            files.append((relative, try String(contentsOfFile: root + "/" + relative, encoding: .utf8)))
        }
        let scanned = files.count
        // An extension's tests run in the suite its type declares, which may live in another file.
        let traited = files.reduce(into: Set<String>()) { $0.formUnion(Self.traitedTypes(in: $1.text)) }
        let offenders = files.flatMap { file in
            Self.uncheckedSuites(in: file.text, traited: traited).map { "\(file.path):\($0.line): \($0.name)" }
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

    /// MainPaneGutterSuites' pattern: tests in `extension Parent { struct Child { ... } }` run under
    /// Parent, so Parent's declaration, here or in another file, must carry the trait.
    @Test func theScanFindsTestsInAnExtensionOfATypeWithoutTheTrait() {
        let opens = """
        import AppKit
        extension Unchecked {
            @MainActor struct Child {
                @Test func a() { let w = NSWindow(); w.close() }
            }
        }
        extension Elsewhere: Sendable { @Test func b() {} }
        extension Checked.Nested { @Test func c() {} }
        @Suite(.closesItsWindows) struct Checked { struct Nested {} }
        extension NSWindow { func helper() {} }
        """
        #expect(Self.uncheckedSuites(in: opens).map(\.name) == ["extension Unchecked", "extension Elsewhere"])
        #expect(Self.uncheckedSuites(in: opens, traited: ["Elsewhere"]).map(\.name) == ["extension Unchecked"])
        #expect(Self.traitedTypes(in: opens) == ["Checked"])
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
        pattern: #"^\s*(?:@\w+(?:\([^\n]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final|nonisolated)\s+)*(struct|class|enum|actor|extension)\s+(\w+)"#
    )

    /// The top-level types in `text` that hold `@Test`s and lack the trait, and the top-level
    /// extensions that hold `@Test`s of a type that lacks it (not in `traited` nor declared with it
    /// in `text`), when `text` opens a window; with 1-based declaration lines.
    static func uncheckedSuites(in text: String, traited: Set<String> = []) -> [Suite] {
        let code = codeOnly(text)
        guard let opensWindow, opensWindow.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil else { return [] }
        let known = traited.union(traitedTypes(in: text))
        return topLevelBlocks(in: code).compactMap { block in
            guard block.hasTest else { return nil }
            if block.isExtension { return known.contains(block.name) ? nil : Suite(line: block.line, name: "extension \(block.name)") }
            return block.hasTrait ? nil : Suite(line: block.line, name: block.name)
        }
    }

    /// The top-level types `text` declares with the trait.
    static func traitedTypes(in text: String) -> Set<String> {
        Set(topLevelBlocks(in: codeOnly(text)).filter { !$0.isExtension && $0.hasTrait }.map(\.name))
    }

    /// A top-level declaration or extension: its 1-based line, its type's name (an extension of
    /// `Outer.Inner` is `Outer`'s), and whether its body holds `@Test`s and its attributes the trait.
    struct Block {
        let line: Int
        let name: String
        let isExtension: Bool
        let hasTest: Bool
        let hasTrait: Bool
    }

    static func topLevelBlocks(in code: String) -> [Block] {
        guard let declaration else { return [] }
        let lines = code.components(separatedBy: "\n")
        var found: [Block] = []
        var depth = 0
        var current: (line: Int, name: String, isExtension: Bool)?
        var opened = false
        var hasTest = false
        for (index, line) in lines.enumerated() {
            if depth == 0, current == nil,
               let match = declaration.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let kind = Range(match.range(at: 1), in: line), let name = Range(match.range(at: 2), in: line) {
                current = (index, String(line[name]), line[kind] == "extension")
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
                    if let block = current, opened, depth == 0 {
                        found.append(Block(line: block.line + 1, name: block.name, isExtension: block.isExtension, hasTest: hasTest,
                                           hasTrait: attributes(above: block.line, in: lines).contains(trait)))
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
