import Foundation
import Testing
@testable import CmuxNextApp

/// The App's search for a bare file name a reply wrote: exact names only, files only, and never
/// inside hidden folders.
@MainActor
struct AgentReplyNamesTests {
    @Test func findsFilesOfExactlyThatNameInSubfolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reply-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["scripts", "outputs/2026-10-21", ".git/hooks", "next-sync.py.d"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["scripts/next-sync.py", "outputs/2026-10-21/next-sync.py", "scripts/next-sync.pyc", ".git/hooks/next-sync.py"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(file))
        }
        let found = await AgentReplyNames().find(["next-sync.py", "missing.py"], in: [root.path])
        // The temporary folder may come back as /private/var or /var: compare the ends.
        let paths = found["next-sync.py"] ?? []
        #expect(paths.count == 2)
        #expect(paths.contains { $0.hasSuffix("/scripts/next-sync.py") })
        #expect(paths.contains { $0.hasSuffix("/outputs/2026-10-21/next-sync.py") })
        #expect(!paths.contains { $0.contains("/.git/") })
        #expect(found["missing.py"]?.isEmpty ?? true)
    }
}
