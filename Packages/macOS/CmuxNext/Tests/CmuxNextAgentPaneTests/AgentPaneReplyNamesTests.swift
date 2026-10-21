import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Bare file names in replies (`next-sync.py` for `scripts/next-sync.py`): which text counts as
/// one, that a found file still passes the deny list and the roots, and what a failed open says.
@MainActor
struct AgentPaneReplyNamesTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test(arguments: ["next-sync.py", "foo.test.ts", "README.md", "package.json", "console.log", ".gitignore.bak"])
    func bareNames(_ text: String) {
        #expect(AgentPaneReplyPaths.isBareName(text))
    }

    @Test(arguments: ["", "1.5", "4.5", "src/app.ts", "~/notes.md", "/repo/app.ts", "app.ts:42", "Makefile", "file.12", "file:///a.ts"])
    func notBareNames(_ text: String) {
        #expect(!AgentPaneReplyPaths.isBareName(text))
    }

    /// The search's candidates are checked like written paths: the first inside a root that is
    /// not a secret wins, in the order the search gave; only bare names are searched for.
    @Test func aFoundFileStillPassesTheDenyListAndTheRoots() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("reply-names-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("repo"), outside = base.appendingPathComponent("elsewhere")
        for folder in [root.appendingPathComponent("scripts"), root.appendingPathComponent("keys"), outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let good = root.appendingPathComponent("scripts/next-sync.py"), elsewhere = outside.appendingPathComponent("next-sync.py")
        let secret = root.appendingPathComponent("keys/server.pem")
        for file in [good, elsewhere, secret] { try Data("x".utf8).write(to: file) }
        let paths = AgentPaneReplyPaths(roots: [root.path], home: base.path, base: root.path)
        let model = AgentPaneModel(host: NoHost())
        var asked: [String] = []
        model.replyLinks.findByName = { names, _ in
            asked = names.sorted()
            return ["next-sync.py": [elsewhere.path, good.path], "server.pem": [secret.path]]
        }
        let found = await model.resolveNames(["next-sync.py", "server.pem", "src/next-sync.py", "1.5"], resolver: paths)
        #expect(asked == ["next-sync.py", "server.pem"])
        #expect(found["next-sync.py"]?.place == .root)
        #expect(found["next-sync.py"]?.path == AcpmuxPathPolicy.canonical(good.path))
        #expect(found["server.pem"] == nil)
    }

    /// A person's click on a chip that does not open is told why; a call without a click is not.
    @Test(arguments: [true, false])
    func aFailedOpenSaysWhyOnlyForAClick(clicked: Bool) async {
        let model = AgentPaneModel(host: NoHost())
        var notices: [String] = []
        model.replyLinks.notice = { notices.append($0) }
        if clicked { model.transport.gestures.record(click: true) }
        _ = await model.respond(to: .openPath("build_compare.py", line: nil))
        if clicked {
            #expect(notices.count == 1)
            #expect(notices.first?.contains("build_compare.py") == true)
        } else {
            #expect(notices.isEmpty)
        }
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
