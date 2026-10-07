import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AgentPaneDirectoryListingTests {
    private func withTree(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-directory-\(UUID().uuidString)")
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
