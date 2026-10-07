import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AgentPaneDirectoryListingTests {
    private func withTree(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("cmux-directory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func listsReadableVisibleDirectoriesAndStopsParentAtRoot() throws {
        try withTree { root in
            let nested = root.appendingPathComponent("nested")
            let hidden = root.appendingPathComponent(".hidden")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
            let result: AgentPaneDirectoryListing
            switch AgentPaneDirectoryListing.list(path: root.path, roots: [root.path], home: root.path) {
            case .success(let value): result = value
            case .failure(let failure): Issue.record("unexpected listing failure: \(failure)"); return
            }
            #expect(result.path == root.path)
            #expect(result.parent == nil)
            #expect(result.directories == [nested.path])
            #expect(AgentPaneDirectoryListing.list(path: "~", roots: [root.path], home: root.path) == .success(result))
        }
    }

    @Test func listsNestedDirectoryWithAllowedParent() throws {
        try withTree { root in
            let nested = root.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let result: AgentPaneDirectoryListing
            switch AgentPaneDirectoryListing.list(path: nested.path, roots: [root.path], home: root.path) {
            case .success(let value): result = value
            case .failure(let failure): Issue.record("unexpected listing failure: \(failure)"); return
            }
            #expect(result.parent == root.path)
        }
    }

    @Test func homeListingCanReachWorkspaceWithoutExposingHiddenChildren() throws {
        try withTree { root in
            let workspace = root.appendingPathComponent("workspace")
            let hidden = root.appendingPathComponent(".credentials")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
            let result: AgentPaneDirectoryListing
            switch AgentPaneDirectoryListing.list(path: "~", roots: [root.path, workspace.path], home: root.path) {
            case .success(let value): result = value
            case .failure(let failure): Issue.record("unexpected listing failure: \(failure)"); return
            }
            #expect(result.path == root.path)
            #expect(result.directories == [workspace.path])
        }
    }

    @Test func hidesCredentialDirectoriesAndRejectsDirectCredentialBrowsing() throws {
        try withTree { root in
            let visible = root.appendingPathComponent("visible")
            let ssh = root.appendingPathComponent(".ssh")
            let gnupg = root.appendingPathComponent(".gnupg")
            let keychains = root.appendingPathComponent("Library/Keychains")
            let github = root.appendingPathComponent(".config/gh")
            for directory in [visible, ssh, gnupg, keychains, github] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            let result: AgentPaneDirectoryListing
            switch AgentPaneDirectoryListing.list(path: root.path, roots: [root.path], home: root.path) {
            case .success(let value): result = value
            case .failure(let failure): Issue.record("unexpected listing failure: \(failure)"); return
            }
            #expect(result.directories == [visible.path])
            #expect(AgentPaneDirectoryListing.list(path: keychains.path, roots: [root.path], home: root.path) == .failure(.unreadable))
        }
    }

    @Test func rejectsOutsideAndNonDirectoryPaths() throws {
        try withTree { root in
            let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            let file = root.appendingPathComponent("file")
            try Data("x".utf8).write(to: file)
            #expect(AgentPaneDirectoryListing.list(path: outside.path, roots: [root.path], home: root.path) == .failure(.outsideRoots))
            #expect(AgentPaneDirectoryListing.list(path: file.path, roots: [root.path], home: root.path) == .failure(.notDirectory))
        }
    }

    @Test func rejectsUnreadableDirectories() throws {
        try withTree { root in
            let blocked = root.appendingPathComponent("blocked")
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
            #expect(AgentPaneDirectoryListing.list(path: blocked.path, roots: [root.path], home: root.path) == .failure(.unreadable))
        }
    }

    @Test func rejectsSymlinkThatEscapesTheAllowedRoot() throws {
        try withTree { root in
            let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            let link = root.appendingPathComponent("escape")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            #expect(AgentPaneDirectoryListing.list(path: link.path, roots: [root.path], home: root.path) == .failure(.outsideRoots))
        }
    }
}
