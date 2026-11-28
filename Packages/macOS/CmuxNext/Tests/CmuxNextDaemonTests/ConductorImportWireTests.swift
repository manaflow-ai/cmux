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
        "recipe": {"project_path": "/Users/me/src/app", "setup": "bun install", "run": "bun dev", "include": [".env"]},
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
        #expect(plan.hasConductor)
        #expect(plan.cleanup == ["ws-half"])
        #expect(plan.projects.first?.envNames == ["API_KEY"])
        #expect(plan.warnings.map(\.code) == ["archive-deletes-folder"])
        // Only checked live workspaces of imported projects are made.
        #expect(plan.adopting.map(\.workspace.id) == ["w-lima"])
        #expect(plan.adopting.first?.workspace.chats?.transcripts == 2)
        #expect(plan.recoverable.map(\.id) == ["w-oslo"])
        #expect(plan.recoverable.first?.disposition.from == "0123abcd")
        // A recipe saves as cmux's worktree recipe; a project without one (r2) saves none.
        #expect(plan.recipes.map(\.project.repoID) == ["r1"])
        #expect(plan.recipes.first?.recipe.worktree == .object([
            "setup": .string("bun install"), "run": .string("bun dev"), "include": .array([.string(".env")]),
        ]))
    }

    @Test func nothingFoundIsNoPlan() throws {
        let reply = try JSONDecoder().decode(ConductorImportReply.self, from: Data(#"{"found": {}, "plan": null}"#.utf8))
        #expect(reply.plan == nil)
        let refused = try JSONDecoder().decode(ConductorImportReply.self,
                                               from: Data(#"{"found": {}, "plan": null, "error": "ledger from a newer cmux"}"#.utf8))
        #expect(refused.error == "ledger from a newer cmux")
    }
    @Test func genericDetectionCarriesCountsWithoutInventingAWorkspaceCount() throws {
        let json = #"{"candidate_folders":{"codex":2,"opencode":1},"has_conductor":false,"card":{"id":"agents.conductor","kind":"conductor","name":"Agent worktrees","count":null}}"#
        let detection = try JSONDecoder().decode(ConductorImportDetection.self, from: Data(json.utf8))
        #expect(detection.candidateFolders == ["codex": 2, "opencode": 1])
        #expect(!detection.hasConductor)
        #expect(detection.card?.count == nil)
        #expect(detection.card?.id == "agents.conductor")
    }

    @Test func oldDetectionAndGenericPlansKeepTheirSourceMeaning() throws {
        let old = try JSONDecoder().decode(ConductorImportDetection.self, from: Data(#"{"found":{}}"#.utf8))
        #expect(old.hasConductor && old.card == nil && old.candidateFolders.isEmpty)
        let json = #"{"plan":{"cloud_shutdown":"","has_conductor":false,"projects":[],"cleanup":[],"warnings":[]}}"#
        let reply = try JSONDecoder().decode(ConductorImportReply.self, from: Data(json.utf8))
        #expect(reply.plan?.hasConductor == false)
    }

}
