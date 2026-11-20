import AppKit
import CmuxNextDaemon
@testable import CmuxNextImportCards
import Foundation
import Testing

/// Import from Conductor's run (``ConductorImport``) against a fake daemon and host: when the
/// preview shows, what a failed close or a failed project add does to the run, and what is
/// recorded in the import's ledger.
@MainActor @Suite(.serialized)
struct ConductorImportRunTests {
    private struct Broke: Error {}

    /// The run's toasts read `NSApp`'s windows (none here, so none shows).
    init() { _ = NSApplication.shared }

    /// The daemon as the run sees it: a fixed plan and listing, and every call recorded.
    @MainActor final class Daemon: ConductorImportDaemon {
        var reply: ConductorImportReply
        var listed: [String] = []
        var closeError: (any Error)?
        var refusedPaths: Set<String> = []
        var refusedRecipes: Set<String> = []
        private(set) var recipes: [String: CmuxNextDaemon.JSONValue] = [:]
        var refusedStage: ConductorImportStage?
        var recordError: any Error = DaemonError.command(
            cmd: "conductor_import.record", message: "taken", code: "validation.invalid",
            details: CmuxNextDaemon.JSONValue.object(["field": .string("cmux_workspace")]))
        private(set) var closed: [WorkspaceKey] = []
        private(set) var added: [String] = []
        private(set) var records: [(workspace: String, stage: ConductorImportStage)] = []
        private(set) var completed: [Bool] = []

        init(_ reply: ConductorImportReply) { self.reply = reply }

        func plan() async throws -> ConductorImportReply { reply }
        func projectPaths(limit: Int) async throws -> [String] { listed }

        func closeWorkspace(_ key: WorkspaceKey) async throws {
            if let closeError { throw closeError }
            closed.append(key)
        }

        func addProject(path: String, idempotencyKey: String) async throws {
            if refusedPaths.contains(path) { throw Broke() }
            added.append(path)
        }

        func saveRecipe(_ recipe: ConductorImportPlan.Recipe, idempotencyKey: String) async throws {
            if refusedRecipes.contains(recipe.projectPath) { throw Broke() }
            recipes[recipe.projectPath] = recipe.worktree
        }

        func record(workspace: String, stage: ConductorImportStage, cmuxWorkspace: String?, runCompleted: Bool,
                    idempotencyKey: String) async throws {
            if stage == refusedStage { throw recordError }
            records.append((workspace, stage))
            completed.append(runCompleted)
        }
    }

    /// The App's side: the open workspaces by id, and the workspaces the run opens.
    @MainActor final class Host: ConductorImportHost {
        var keys: [String: WorkspaceKey] = [:]
        private(set) var opened: [String] = []
        var conductorDaemon: DaemonConnection? { nil }
        func conductorWorkspaceKey(_ id: String) -> WorkspaceKey? { keys[id] }
        func openConductorWorkspace(folder: String, name: String, key: WorkspaceKey) async throws -> String {
            opened.append(folder)
            return key.rawValue
        }
    }

    /// Asks nothing: records whether the preview showed and answers Import.
    @MainActor final class Preview {
        private(set) var shown = 0
        func confirm(_ plan: ConductorImportPlan) -> Bool {
            shown += 1
            return true
        }
    }

    private static func workspace(_ id: String, kind: String, checked: Bool) -> String {
        #"{"id":"\#(id)","name":"\#(id)","branch":"b-\#(id)","path":"/w/\#(id)","disposition":{"kind":"\#(kind)"},"checked":\#(checked),"chats":null}"#
    }

    private static func project(_ id: String, _ workspaces: [String], recipe: String = "null") -> String {
        #"{"repo_id":"\#(id)","name":"\#(id)","path":"/src/\#(id)","skipped":null,"setup":null,"teardown":null,"worktreeinclude":[],"env_names":[],"workspaces":[\#(workspaces.joined(separator: ","))],"recipe":\#(recipe)}"#
    }

    private static func recipe(_ id: String) -> String {
        #"{"project_path":"/real/\#(id)","setup":"bun install","run":"bun dev","include":[".env"]}"#
    }

    private static func reply(_ projects: [String], cleanup: [String] = []) throws -> ConductorImportReply {
        let cleanupJSON = cleanup.map { "\"\($0)\"" }.joined(separator: ",")
        let json = #"{"plan":{"cloud_shutdown":"2026-11-20","projects":[\#(projects.joined(separator: ","))],"cleanup":[\#(cleanupJSON)],"warnings":[]}}"#
        return try JSONDecoder().decode(ConductorImportReply.self, from: Data(json.utf8))
    }

    private static func run(_ daemon: Daemon, _ host: Host, _ preview: Preview) async throws -> Int? {
        try await ConductorImport(host: host, daemon: { daemon }, confirm: { preview.confirm($0) }).run()
    }

    /// The cut-off run's workspace will not close: the run stops before it makes a replacement,
    /// so there are never two.
    @Test func aFailedCleanupCloseStopsTheRun() async throws {
        let daemon = Daemon(try Self.reply([Self.project("r1", [Self.workspace("w1", kind: "adopt", checked: true)])],
                                           cleanup: ["half"]))
        daemon.listed = ["/src/r1"]
        daemon.closeError = DaemonError.command(cmd: "close-workspace", message: "refused", code: "workspace.busy")
        let host = Host()
        host.keys["half"] = WorkspaceKey(rawValue: "key-half")
        await #expect(throws: DaemonError.self) { _ = try await Self.run(daemon, host, Preview()) }
        #expect(host.opened.isEmpty && daemon.records.isEmpty)
    }

    /// One that is already gone, by the store (no key) or by the daemon's answer, is no failure.
    @Test func aCleanupWorkspaceAlreadyGoneIsNoFailure() async throws {
        let daemon = Daemon(try Self.reply([Self.project("r1", [Self.workspace("w1", kind: "adopt", checked: true)])],
                                           cleanup: ["gone", "ended"]))
        daemon.listed = ["/src/r1"]
        daemon.closeError = DaemonError.command(cmd: "close-workspace", message: "no such workspace", code: "selector.not_found",
                                                details: CmuxNextDaemon.JSONValue.object(["scope": .string("workspace")]))
        let host = Host()
        host.keys["ended"] = WorkspaceKey(rawValue: "key-ended")
        #expect(try await Self.run(daemon, host, Preview()) == 1)
        #expect(host.opened == ["/w/w1"])
    }

    /// Another run took the workspace after this one's pending record, so its done record is
    /// refused: the workspace this run made closes instead of staying open beside the other.
    @Test func aRefusedDoneRecordClosesTheWorkspaceItMade() async throws {
        let daemon = Daemon(try Self.reply([Self.project("r1", [Self.workspace("w1", kind: "adopt", checked: true)])]))
        daemon.listed = ["/src/r1"]
        daemon.refusedStage = .done
        let host = Host()
        await #expect(throws: DaemonError.self) { _ = try await Self.run(daemon, host, Preview()) }
        #expect(host.opened == ["/w/w1"])
        #expect(daemon.closed.count == 1)
    }

    /// A done record that fails any other way (a timeout, a dropped connection) may have been kept:
    /// the workspace stays open, and the ledger's pending entry still names it for the next run.
    @Test func anUncertainDoneRecordFailureKeepsTheWorkspace() async throws {
        let daemon = Daemon(try Self.reply([Self.project("r1", [Self.workspace("w1", kind: "adopt", checked: true)])]))
        daemon.listed = ["/src/r1"]
        daemon.refusedStage = .done
        daemon.recordError = Broke()
        let host = Host()
        await #expect(throws: Broke.self) { _ = try await Self.run(daemon, host, Preview()) }
        #expect(host.opened == ["/w/w1"])
        #expect(daemon.closed.isEmpty)
    }

    /// A repository that cannot be added keeps its workspaces unrecorded (Import Again offers
    /// them), the other repository's still come over, and the run ends failed.
    @Test func aFailedProjectAddLeavesItsWorkspacesImportable() async throws {
        let daemon = Daemon(try Self.reply([
            Self.project("r1", [Self.workspace("w1", kind: "adopt", checked: true)]),
            Self.project("r2", [Self.workspace("w2", kind: "adopt", checked: true)]),
        ]))
        daemon.refusedPaths = ["/src/r2"]
        let host = Host()
        await #expect(throws: ConductorImportFailure.projects(["r2"])) { _ = try await Self.run(daemon, host, Preview()) }
        #expect(daemon.added == ["/src/r1"])
        #expect(host.opened == ["/w/w1"])
        #expect(daemon.records.map(\.workspace) == ["w1", "w1"])
    }

    /// Nothing to open, but a repository not listed yet: the preview shows and Import adds it.
    @Test func aProjectOnlyPlanShowsThePreview() async throws {
        let daemon = Daemon(try Self.reply([Self.project("r1", [Self.workspace("w1", kind: "already-imported", checked: false)])]))
        let preview = Preview()
        #expect(try await Self.run(daemon, Host(), preview) == 0)
        #expect(preview.shown == 1)
        #expect(daemon.added == ["/src/r1"])
    }

    /// Only archived workspaces to explain: the preview shows (they are left out, and it says so).
    @Test func aRecoverableOnlyPlanShowsThePreview() async throws {
        let daemon = Daemon(try Self.reply([Self.project("r1", [Self.workspace("w1", kind: "recoverable", checked: false)])]))
        daemon.listed = ["/src/r1"]
        let preview = Preview()
        #expect(try await Self.run(daemon, Host(), preview) == 0)
        #expect(preview.shown == 1)
        #expect(daemon.added.isEmpty && daemon.records.isEmpty)
    }

    /// Everything here already and every repository listed: no preview, nothing done.
    @Test func nothingLeftShowsNoPreview() async throws {
        let daemon = Daemon(try Self.reply([Self.project("r1", [Self.workspace("w1", kind: "already-imported", checked: false)])]))
        daemon.listed = ["/src/r1"]
        let preview = Preview()
        #expect(try await Self.run(daemon, Host(), preview) == 0)
        #expect(preview.shown == 0)
        #expect(daemon.added.isEmpty)
    }

    /// Each project's recipe is saved on the cmux project the plan names, as the preview listed it,
    /// even when the project was listed already.
    @Test func eachProjectsRecipeIsSavedOnItsProject() async throws {
        let daemon = Daemon(try Self.reply([
            Self.project("r1", [Self.workspace("w1", kind: "already-imported", checked: false)], recipe: Self.recipe("r1")),
        ]))
        daemon.listed = ["/src/r1"]
        let preview = Preview()
        #expect(try await Self.run(daemon, Host(), preview) == 0)
        #expect(preview.shown == 1)
        #expect(daemon.recipes["/real/r1"] == CmuxNextDaemon.JSONValue.object([
            "setup": .string("bun install"), "run": .string("bun dev"), "include": .array([.string(".env")]),
        ]))
        let lines = ConductorImport.previewLines(daemon.reply.plan!)
        #expect(lines.contains("• r1: setup: bun install · run: bun dev · include: .env"))
    }

    /// A recipe that cannot be saved fails the run at its end; the workspaces still come over.
    @Test func aFailedRecipeSaveFailsTheRunAfterTheWorkspaces() async throws {
        let daemon = Daemon(try Self.reply([
            Self.project("r1", [Self.workspace("w1", kind: "adopt", checked: true)], recipe: Self.recipe("r1")),
        ]))
        daemon.refusedRecipes = ["/real/r1"]
        let host = Host()
        await #expect(throws: ConductorImportFailure.recipes(["r1"])) { _ = try await Self.run(daemon, host, Preview()) }
        #expect(host.opened == ["/w/w1"])
        // A run with a recipe it could not save is not recorded as complete.
        #expect(!daemon.completed.contains(true))
    }
}
