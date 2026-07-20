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

    @Test("subtree mode authorizes descendants of a visible directory")
    func subtreeDirectoryAuthorization() {
        let scope = scope(
            text: "ls /safe/project",
            accessMode: .subtree
        )
        #expect(scope.canonicalPath(for: "/safe/project/src/main.swift") == "/safe/project/src/main.swift")
        #expect(scope.canonicalDirectoryListPath(for: "/safe/project/src") == "/safe/project/src")
    }

    @Test("one-level mode preserves visible-directory parity")
    func oneLevelDirectoryAuthorization() {
        let scope = scope(
            text: "ls /safe/project",
            accessMode: .oneLevel
        )
        #expect(scope.canonicalPath(for: "/safe/project/readme.md") == "/safe/project/readme.md")
        #expect(scope.canonicalPath(for: "/safe/project/src/main.swift") == nil)
        #expect(scope.canonicalDirectoryListPath(for: "/safe/project") == "/safe/project")
        #expect(scope.canonicalDirectoryListPath(for: "/safe/project/src") == nil)
    }

    @Test("subtree mode denies a symlink escape from a visible directory")
    func subtreeDeniesSymlinkEscape() {
        let scope = scope(
            text: "ls /safe/project",
            files: ["/outside/secret.txt"],
            symlinks: ["/safe/project/src/link": "/outside/secret.txt"],
            accessMode: .subtree
        )
        #expect(scope.canonicalPath(for: "/safe/project/src/link") == nil)
    }

    @Test("subtree mode uniformly denies existing and missing paths outside visible scope")
    func subtreeUniformOutsideDenial() {
        let scope = scope(
            text: "ls /safe/project",
            files: ["/outside/existing.txt"],
            accessMode: .subtree
        )
        #expect(scope.canonicalPath(for: "/outside/existing.txt") == nil)
        #expect(scope.canonicalPath(for: "/outside/missing.txt") == nil)
        #expect(scope.canonicalDirectoryListPath(for: "/outside/existing") == nil)
        #expect(scope.canonicalDirectoryListPath(for: "/outside/missing") == nil)
    }

    @Test("an exact visible file reaches the reader for list file-not-found semantics")
    func exactVisibleFileMayReachListReader() {
        let scope = scope(text: "cat /safe/project/src/main.swift")
        #expect(scope.canonicalDirectoryListPath(for: "/safe/project/src/main.swift") == "/safe/project/src/main.swift")
    }
    @Test("visible scan deduplicates canonical identities in first-seen order")
    func visibleScanCanonicalIdentityDeduplication() {
        let canonicalizer = ChatArtifactPathCanonicalizer { path in
            path == "/safe/report.txt" ? "/safe/Report.txt" : path
        }
        let scope = TerminalArtifactScope(
            terminalText: "cat /safe/report.txt /safe/notes.txt /safe/Report.txt",
            workingDirectory: "/safe",
            resolver: FakeResolver(
                files: ["/safe/report.txt", "/safe/notes.txt", "/safe/Report.txt"],
                directories: ["/safe"],
                symlinks: [:]
            ),
            canonicalizer: canonicalizer
        )

        #expect(scope.artifactPaths() == ["/safe/Report.txt", "/safe/notes.txt"])
    }

    @Test("request resolution shares the visible-scan canonical identity")
    func requestResolutionUsesCanonicalIdentity() {
        let canonicalizer = ChatArtifactPathCanonicalizer { path in
            path == "/safe/report.txt" ? "/safe/Report.txt" : path
        }
        let scope = TerminalArtifactScope(
            terminalText: "cat /safe/report.txt",
            workingDirectory: "/safe",
            resolver: FakeResolver(
                files: ["/safe/report.txt", "/safe/Report.txt"],
                directories: ["/safe"],
                symlinks: [:]
            ),
            canonicalizer: canonicalizer
        )

        #expect(scope.canonicalPath(for: "/safe/report.txt") == "/safe/Report.txt")
        #expect(scope.canonicalPath(for: "/safe/Report.txt") == "/safe/Report.txt")
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
        symlinks: [String: String] = [:],
        accessMode: ChatArtifactScope.DirectoryAccessMode = .oneLevel
    ) -> TerminalArtifactScope {
        TerminalArtifactScope(
            terminalText: text,
            workingDirectory: workingDirectory,
            resolver: FakeResolver(files: files, directories: directories, symlinks: symlinks),
            directoryAccessMode: accessMode
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
