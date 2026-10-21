import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Bare file names in replies (`next-sync.py` for `scripts/next-sync.py`): which text counts as
/// one, which found file wins, and that a found file still passes the deny list and the roots.
struct AgentPaneReplyNamesTests {
    @Test(arguments: ["next-sync.py", "foo.test.ts", "README.md", "package.json", "console.log", ".gitignore.bak"])
    func bareNames(_ text: String) {
        #expect(AgentPaneReplyPaths.isBareName(text))
    }

    @Test(arguments: ["", "1.5", "4.5", "src/app.ts", "~/notes.md", "/repo/app.ts", "app.ts:42", "Makefile", "file.12", "file:///a.ts"])
    func notBareNames(_ text: String) {
        #expect(!AgentPaneReplyPaths.isBareName(text))
    }

    @Test func rankingPrefersTheFewestFoldersThenTheShorterPathThenTheName() {
        let ranked = AgentPaneReplyPaths.ranked([
            "/repo/outputs/2026-10-21/deep/build.py",
            "/repo/scripts/build.py",
            "/repo/a/build.py",
            "/repo/outputs/build.py",
        ])
        #expect(ranked == ["/repo/a/build.py", "/repo/scripts/build.py", "/repo/outputs/build.py", "/repo/outputs/2026-10-21/deep/build.py"])
    }

    /// A found file goes through the same checks as a written path: inside a root, not a secret.
    @Test func aFoundFileStillPassesTheDenyListAndTheRoots() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("reply-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("repo"), outside = base.appendingPathComponent("elsewhere")
        for folder in [root.appendingPathComponent("scripts"), outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for file in [root.appendingPathComponent("scripts/next-sync.py"), root.appendingPathComponent("scripts/.env.local"),
                     outside.appendingPathComponent("next-sync.py")] {
            try Data("x".utf8).write(to: file)
        }
        let paths = AgentPaneReplyPaths(roots: [root.path], home: base.path, base: root.path)
        // Written as a bare name, the file is not in the root itself.
        #expect(paths.resolve("next-sync.py")?.place == .missing)
        #expect(paths.resolve(root.appendingPathComponent("scripts/next-sync.py").path)?.place == .root)
        #expect(paths.resolve(root.appendingPathComponent("scripts/.env.local").path)?.place == .denied)
        #expect(paths.resolve(outside.appendingPathComponent("next-sync.py").path)?.place == .outside)
    }

    @Test func aMissingFileSaysWhichNameWasNotFound() throws {
        let notice = try #require(AgentPaneModel.openFailureNotice(.pathInvalid, path: "outputs/build_compare.py"))
        #expect(notice.contains("build_compare.py"))
        #expect(!notice.contains("outputs/"))
    }

    @Test(arguments: [AgentPaneReplyError.gestureRequired, .notConfirmed])
    func declinedOrUnclickedOpensSayNothing(_ error: AgentPaneReplyError) {
        #expect(AgentPaneModel.openFailureNotice(error, path: "app.ts") == nil)
    }

    @Test(arguments: [AgentPaneReplyError.pathDenied, .pathOutsideRoots, .openFailed])
    func otherFailuresSayWhy(_ error: AgentPaneReplyError) {
        #expect(AgentPaneModel.openFailureNotice(error, path: "app.ts")?.isEmpty == false)
    }
}
