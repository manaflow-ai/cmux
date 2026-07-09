import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("TerminalArtifactScope")
struct TerminalArtifactScopeTests {
    @Test("allows a path present on screen")
    func allowsOnScreenPath() {
        let scope = scope(text: "cat /safe/file.txt")
        #expect(scope.canonicalPath(for: "/safe/file.txt") == "/safe/file.txt")
    }

    @Test("denies a path not present on screen")
    func deniesOffScreenPath() {
        let scope = scope(text: "cat /safe/file.txt")
        #expect(scope.canonicalPath(for: "/safe/other.txt") == nil)
    }

    @Test("denies unrelated absolute path when absent")
    func deniesEtcPasswdWhenAbsent() {
        let scope = scope(text: "cat /safe/file.txt", files: ["/safe/file.txt", "/etc/passwd"])
        #expect(scope.canonicalPath(for: "/etc/passwd") == nil)
    }

    @Test("denies traversal to sibling even when sibling token appears")
    func deniesTraversalSiblingEscape() {
        let scope = scope(text: "cat /safe/file.txt")
        #expect(scope.canonicalPath(for: "/safe/file.txt/../other.txt") == nil)
    }

    @Test("denies symlink escape")
    func deniesSymlinkEscape() {
        let scope = scope(
            text: "cat /safe/file.txt",
            files: ["/safe/link", "/etc/passwd"],
            symlinks: ["/safe/link": "/etc/passwd"]
        )
        #expect(scope.canonicalPath(for: "/safe/link") == nil)
    }

    @Test("resolves relative token against cwd")
    func resolvesRelativeTokenAgainstCwd() {
        let scope = scope(text: "vim src/main.swift", workingDirectory: "/safe/project")
        #expect(scope.canonicalPath(for: "/safe/project/src/main.swift") == "/safe/project/src/main.swift")
        #expect(scope.canonicalPath(for: "src/main.swift") == "/safe/project/src/main.swift")
    }

    @Test("uses canonical comparison")
    func canonicalComparison() {
        let scope = scope(text: "cat /safe/project/./src/../src/main.swift", workingDirectory: "/safe/project")
        #expect(scope.canonicalPath(for: "/safe/project/src/main.swift") == "/safe/project/src/main.swift")
    }

    private func scope(
        text: String,
        workingDirectory: String? = "/safe/project",
        files: Set<String> = [
            "/safe/file.txt",
            "/safe/project/src/main.swift",
            "/safe/project/notes/todo.md",
        ],
        directories: Set<String> = ["/safe", "/safe/project", "/safe/project/src", "/safe/project/notes"],
        symlinks: [String: String] = [:]
    ) -> TerminalArtifactScope {
        TerminalArtifactScope(
            terminalText: text,
            workingDirectory: workingDirectory,
            resolver: FakeResolver(files: files, directories: directories, symlinks: symlinks)
        )
    }

    private struct FakeResolver: ChatArtifactScope.FileSystemResolving {
        let files: Set<String>
        let directories: Set<String>
        let symlinks: [String: String]

        func resolveSymlinks(of path: String) -> String? {
            let standardized = (path as NSString).standardizingPath
            return symlinks[standardized] ?? standardized
        }

        func isDirectory(_ path: String) -> Bool? {
            let standardized = (path as NSString).standardizingPath
            if directories.contains(standardized) { return true }
            if files.contains(standardized) || symlinks[standardized] != nil { return false }
            return nil
        }
    }
}
