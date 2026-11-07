@testable import CmuxNextDaemon
import Foundation
import Testing

/// `conductor_import.plan`'s reply as the `cmux-conductor-import` crate serializes it: what
/// the app adopts, what it lists as recoverable, and what it leaves out.
struct ConductorImportWireTests {
    static let reply = """
    {"found": {"database": "/Users/me/Library/Application Support/com.conductor.app/conductor.db", "workspaces": null, "app": null},
     "plan": {"source": "/Users/me/Library/Application Support/com.conductor.app/conductor.db",
      "cloud_read_only": "2026-11-13", "cloud_shutdown": "2026-11-20",
      "projects": [
       {"repo_id": "r1", "name": "app", "path": "/Users/me/src/app", "skipped": null,
        "setup": "bun install", "teardown": null, "run": [{"id": "web", "command": "bun dev"}],
        "aliases": [["CONDUCTOR_PORT", "CMUX_PORT"]], "worktreeinclude": [".env"], "env_names": ["API_KEY"],
        "notes": [{"code": "not-imported", "detail": "spotlight_testing"}],
        "workspaces": [
         {"id": "w-lima", "name": "lima", "branch": "leo/lima", "path": "/Users/me/conductor/workspaces/app/lima",
          "disposition": {"kind": "adopt"}, "checked": true,
          "chats": {"claude_folder": "/Users/me/.claude/projects/-Users-me-conductor-workspaces-app-lima", "transcripts": 2}},
         {"id": "w-done", "name": "kyiv", "branch": "leo/kyiv", "path": "/Users/me/conductor/workspaces/app/kyiv",
          "disposition": {"kind": "adopt"}, "checked": false, "chats": null},
         {"id": "w-oslo", "name": "oslo", "branch": "leo/oslo", "path": "/Users/me/conductor/workspaces/app/oslo",
          "disposition": {"kind": "recoverable", "from": "0123abcd"}, "checked": false, "chats": null},
         {"id": "w-plain", "name": "plain", "branch": null, "path": "/Users/me/conductor/workspaces/app/plain",
          "disposition": {"kind": "skip", "reason": "not-a-worktree"}, "checked": false, "chats": null}]},
       {"repo_id": "r2", "name": "gone", "path": "/nowhere", "skipped": "/nowhere no longer exists",
        "setup": null, "teardown": null, "run": [], "aliases": [], "worktreeinclude": [], "env_names": [], "notes": [],
        "workspaces": [
         {"id": "w-x", "name": "x", "branch": "x", "path": "/nowhere/x", "disposition": {"kind": "skip", "reason": "project"},
          "checked": false, "chats": null}]}],
      "cleanup": ["ws-half"],
      "warnings": [{"code": "archive-deletes-folder", "detail": "Archiving ..."}]}}
    """

    @Test func decodesWhatTheDaemonSends() throws {
        let reply = try JSONDecoder().decode(ConductorImportReply.self, from: Data(Self.reply.utf8))
        let plan = try #require(reply.plan)
        #expect(reply.error == nil)
        #expect(plan.cloudShutdown == "2026-11-20")
        #expect(plan.cleanup == ["ws-half"])
        #expect(plan.projects.first?.envNames == ["API_KEY"])
        #expect(plan.warnings.map(\.code) == ["archive-deletes-folder"])
        // Only checked live workspaces of imported projects are made.
        #expect(plan.adopting.map(\.workspace.id) == ["w-lima"])
        #expect(plan.adopting.first?.workspace.chats?.transcripts == 2)
        #expect(plan.recoverable.map(\.id) == ["w-oslo"])
        #expect(plan.recoverable.first?.disposition.from == "0123abcd")
    }

    @Test func nothingFoundIsNoPlan() throws {
        let reply = try JSONDecoder().decode(ConductorImportReply.self, from: Data(#"{"found": {}, "plan": null}"#.utf8))
        #expect(reply.plan == nil)
        let refused = try JSONDecoder().decode(ConductorImportReply.self,
                                               from: Data(#"{"found": {}, "plan": null, "error": "ledger from a newer cmux"}"#.utf8))
        #expect(refused.error == "ledger from a newer cmux")
    }
}
