import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("ChatArtifactScope")
struct ChatArtifactScopeTests {
    @Test("allows exact referenced file")
    func exactReferencedFile() {
        let scope = scope(referenced: ["/safe/file.txt"])
        #expect(scope.canonicalFilePath(for: "/safe/file.txt") == "/safe/file.txt")
    }

    @Test("allows one file level inside referenced directory")
    func oneLevelInsideReferencedDirectory() {
        let scope = scope(referenced: ["/safe/dir"], directories: ["/safe/dir"])
        #expect(scope.canonicalFilePath(for: "/safe/dir/image.png") == "/safe/dir/image.png")
    }

    @Test("denies two levels deep inside referenced directory")
    func deniesTwoLevelsDeep() {
        let scope = scope(referenced: ["/safe/dir"], directories: ["/safe/dir"])
        #expect(scope.canonicalFilePath(for: "/safe/dir/nested/image.png") == nil)
    }

    @Test("denies parent traversal escape")
    func deniesParentTraversalEscape() {
        let scope = scope(referenced: ["/safe/dir"], directories: ["/safe/dir"])
        #expect(scope.canonicalFilePath(for: "/safe/dir/../secret.txt") == nil)
    }

    @Test("denies symlink escape")
    func deniesSymlinkEscape() {
        let scope = scope(
            referenced: ["/safe/dir"],
            directories: ["/safe/dir"],
            symlinks: ["/safe/dir/link": "/etc/passwd"]
        )
        #expect(scope.canonicalFilePath(for: "/safe/dir/link") == nil)
    }

    @Test("denies relative path")
    func deniesRelativePath() {
        let scope = scope(referenced: ["/safe/file.txt"])
        #expect(scope.canonicalFilePath(for: "safe/file.txt") == nil)
    }

    @Test("denies unrelated absolute path")
    func deniesUnrelatedAbsolutePath() {
        let scope = scope(referenced: ["/safe/file.txt"])
        #expect(scope.canonicalFilePath(for: "/etc/passwd") == nil)
    }

    @Test("list requires the listed directory itself to be referenced")
    func listRequiresExactReferencedDirectory() {
        let scope = scope(
            referenced: ["/safe"],
            directories: ["/safe", "/safe/child"]
        )
        #expect(scope.canonicalDirectoryListPath(for: "/safe") == "/safe")
        #expect(scope.canonicalDirectoryListPath(for: "/safe/child") == nil)
    }

    private func scope(
        referenced: Set<String>,
        directories: Set<String> = [],
        symlinks: [String: String] = [:]
    ) -> ChatArtifactScope {
        ChatArtifactScope(
            referencedPaths: referenced,
            resolver: FakeResolver(directories: directories, symlinks: symlinks)
        )
    }

    private struct FakeResolver: ChatArtifactScope.FileSystemResolving {
        let directories: Set<String>
        let symlinks: [String: String]

        func resolveSymlinks(of path: String) -> String? {
            let standardized = (path as NSString).standardizingPath
            return symlinks[standardized] ?? standardized
        }

        func isDirectory(_ path: String) -> Bool? {
            directories.contains(path)
        }
    }
}
