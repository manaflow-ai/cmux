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

    @Test("subtree mode allows nested descendants and nested directory listings")
    func subtreeAllowsNestedDescendants() {
        let scope = scope(
            referenced: ["/safe/dir"],
            directories: ["/safe/dir", "/safe/dir/nested"],
            accessMode: .subtree
        )
        #expect(scope.canonicalFilePath(for: "/safe/dir/nested/image.png") == "/safe/dir/nested/image.png")
        #expect(scope.canonicalDirectoryListPath(for: "/safe/dir/nested") == "/safe/dir/nested")
    }

    @Test("one-level mode preserves legacy file and list authorization")
    func oneLevelParity() {
        let scope = scope(
            referenced: ["/safe/dir"],
            directories: ["/safe/dir", "/safe/dir/nested"],
            accessMode: .oneLevel
        )
        #expect(scope.canonicalFilePath(for: "/safe/dir/image.png") == "/safe/dir/image.png")
        #expect(scope.canonicalFilePath(for: "/safe/dir/nested/image.png") == nil)
        #expect(scope.canonicalDirectoryListPath(for: "/safe/dir") == "/safe/dir")
        #expect(scope.canonicalDirectoryListPath(for: "/safe/dir/nested") == nil)
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

    @Test("subtree mode denies a symlink escape before containment comparison")
    func subtreeDeniesSymlinkEscape() {
        let scope = scope(
            referenced: ["/safe/dir"],
            directories: ["/safe/dir"],
            symlinks: ["/safe/dir/nested/link": "/outside/secret.txt"],
            accessMode: .subtree
        )
        #expect(scope.canonicalFilePath(for: "/safe/dir/nested/link") == nil)
    }

    @Test("subtree mode uniformly denies existing and missing paths outside scope")
    func subtreeUniformOutsideDenial() {
        let scope = scope(
            referenced: ["/safe/dir"],
            directories: ["/safe/dir", "/outside/existing"],
            accessMode: .subtree
        )
        #expect(scope.canonicalFilePath(for: "/outside/existing/file.txt") == nil)
        #expect(scope.canonicalFilePath(for: "/outside/missing/file.txt") == nil)
        #expect(scope.canonicalDirectoryListPath(for: "/outside/existing") == nil)
        #expect(scope.canonicalDirectoryListPath(for: "/outside/missing") == nil)
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
        symlinks: [String: String] = [:],
        accessMode: ChatArtifactScope.DirectoryAccessMode = .oneLevel
    ) -> ChatArtifactScope {
        ChatArtifactScope(
            referencedPaths: referenced,
            directoryAccessMode: accessMode,
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
