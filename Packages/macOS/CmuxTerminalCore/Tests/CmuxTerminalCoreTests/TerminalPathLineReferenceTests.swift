import Foundation
import Testing
@testable import CmuxTerminalCore

private func existsIn(_ existingPaths: Set<String>) -> @Sendable (String) -> Bool {
    { path in existingPaths.contains((path as NSString).standardizingPath) }
}

@Suite struct TerminalPathLineSuffixSplitTests {
    @Test func splitsTrailingLineNumber() throws {
        let split = try #require("/Users/dev/app/main.swift:42".splitTerminalPathLineSuffix())
        #expect(split.path == "/Users/dev/app/main.swift")
        #expect(split.line == 42)
        #expect(split.column == nil)
    }

    @Test func splitsTrailingLineAndColumn() throws {
        let split = try #require("/Users/dev/app/main.swift:42:5".splitTerminalPathLineSuffix())
        #expect(split.path == "/Users/dev/app/main.swift")
        #expect(split.line == 42)
        #expect(split.column == 5)
    }

    @Test func splitsRelativePathReference() throws {
        let split = try #require("Sources/App.swift:1".splitTerminalPathLineSuffix())
        #expect(split.path == "Sources/App.swift")
        #expect(split.line == 1)
    }

    @Test func returnsNilWhenNoLineSuffix() {
        #expect("/Users/dev/app/main.swift".splitTerminalPathLineSuffix() == nil)
    }

    @Test func returnsNilForNonNumericSuffix() {
        #expect("/Users/dev/app/main.swift:main".splitTerminalPathLineSuffix() == nil)
    }

    @Test func returnsNilForZeroLine() {
        #expect("/Users/dev/app/main.swift:0".splitTerminalPathLineSuffix() == nil)
    }

    @Test func returnsNilForEmptyPath() {
        #expect(":42".splitTerminalPathLineSuffix() == nil)
    }
}

@Suite struct TerminalOpenURLFileReferenceTests {
    @Test func resolvesAbsolutePathWithLine() throws {
        let existingFile = "/Users/dev/project/Sources/App.swift"
        let reference = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFileReference(
                "\(existingFile):42",
                cwd: "/Users/dev/project"
            )
        )
        #expect(reference.path == existingFile)
        #expect(reference.line == 42)
        #expect(reference.column == nil)
    }

    @Test func resolvesAbsolutePathWithLineAndColumn() throws {
        let existingFile = "/Users/dev/project/Sources/App.swift"
        let reference = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFileReference(
                "\(existingFile):42:5",
                cwd: "/Users/dev/project"
            )
        )
        #expect(reference.path == existingFile)
        #expect(reference.line == 42)
        #expect(reference.column == 5)
    }

    @Test func resolvesRelativePathWithLineAgainstCwd() throws {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/Sources/App.swift"
        let reference = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFileReference(
                "Sources/App.swift:1",
                cwd: cwd
            )
        )
        #expect(reference.path == existingFile)
        #expect(reference.line == 1)
    }

    @Test func prefersLiteralPathThatReallyContainsColonNumber() throws {
        let literalPath = "/Users/dev/project/weird:42"
        let reference = try #require(
            TerminalPathResolver(fileExists: existsIn([literalPath])).resolveOpenURLFileReference(
                literalPath,
                cwd: "/Users/dev/project"
            )
        )
        #expect(reference.path == literalPath)
        #expect(reference.line == nil)
    }

    @Test func resolvesPlainExistingPathWithoutLine() throws {
        let existingFile = "/Users/dev/project/README.md"
        let reference = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFileReference(
                existingFile,
                cwd: "/Users/dev/project"
            )
        )
        #expect(reference.path == existingFile)
        #expect(reference.line == nil)
        #expect(reference.column == nil)
    }

    @Test func returnsNilWhenBasePathDoesNotExist() {
        #expect(
            TerminalPathResolver(fileExists: existsIn([])).resolveOpenURLFileReference(
                "Sources/Missing.swift:1",
                cwd: "/Users/dev/project"
            ) == nil
        )
    }

    @Test func neverTreatsWebURLAsFileReference() {
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveOpenURLFileReference(
                "https://example.com:443",
                cwd: "/Users/dev/project"
            ) == nil
        )
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveOpenURLFileReference(
                "http://example.com:80",
                cwd: "/Users/dev/project"
            ) == nil
        )
    }
}

@Suite struct TerminalFileReferenceFileURLTests {
    @Test func encodesLineAndColumnAsFragment() {
        let reference = TerminalFileReference(path: "/Users/dev/app/main.swift", line: 42, column: 5)
        #expect(reference.fileURL.path == "/Users/dev/app/main.swift")
        #expect(reference.fileURL.fragment == "L42:5")
    }

    @Test func encodesLineOnlyAsFragment() {
        let reference = TerminalFileReference(path: "/Users/dev/app/main.swift", line: 42, column: nil)
        #expect(reference.fileURL.fragment == "L42")
    }

    @Test func omitsFragmentWhenNoLine() {
        let reference = TerminalFileReference(path: "/Users/dev/app/main.swift", line: nil, column: nil)
        #expect(reference.fileURL.fragment == nil)
    }
}
