import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// A script makes a workspace with `action.run workspace.newAtBottom` and reads the new workspace's id from the
/// answer's `created`, then goes to it (`goToWorkspace workspace=<id>`): the bench tools in scripts/perf-bench and
/// scripts/cmux-next do. Since a terminal workspace is one daemon request (650fd32b59b9) `created` held only the tab
/// and the terminal, so each of them said that the app made no workspace (a GUI hold on a fleet Mac lost 4 of 4
/// driver runs, 2026-11-12). `created` names the workspace first, then its tab and its terminal, as before.
///
/// The real action on a real same-tree cmux-tui, answered by the control router as the socket answers it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ActionRunCreatedWorkspaceTests {
    @Test(arguments: ["workspace.newAtBottom", "workspace.newAtTop"])
    func aScriptsNewWorkspaceIsNamedFirstInCreated(_ action: String) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            // The path under test is the one request; a daemon without it makes the workspace by `create-workspace`.
            let oneRequest = await connection.makesWorkspaceWithTerminal
            try #require(oneRequest, "this cmux-tui has no create-terminal-workspace-v1")
            let bridge = RegistryControlBridge(registry: services.registry)
            let router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: getpid()),
                                       executor: bridge, configuration: .init(requestDeadline: .seconds(30)),
                                       frameSource: ScriptPaneFocusTests.SoonFrames())
            bridge.attach(to: router)
            let publisher = ControlSnapshotPublisher(router: router, services: services, frames: ScriptPaneFocusTests.SoonFrames())
            publisher.start()
            defer { publisher.stop() }
            @MainActor func call(_ method: String, _ params: [String: CmuxNextSettings.JSONValue] = [:]) async throws -> CmuxNextSettings.JSONValue {
                try await router.handle(ControlRequest(id: "1", method: method, params: params)).get()
            }
            @MainActor func workspaces() async throws -> [[String: CmuxNextSettings.JSONValue]] {
                (try await call("snapshot.get").objectValue?["topology"]?.objectValue?["workspaces"]?.arrayValue ?? []).compactMap(\.objectValue)
            }
            let listed = try await workspaces()
            let before = Set(listed.compactMap { $0["id"]?.stringValue })
            try #require(!before.isEmpty, "the snapshot lists the launch workspace")

            let reply = try await call("action.run", ["action": .string(action), "args": [:], "origin": "script"])
            #expect(reply.objectValue?["ran"] == .bool(true), "\(reply)")
            let created = (reply.objectValue?["created"]?.arrayValue ?? []).compactMap(\.stringValue)
            try #require(created.count == 3, "created names the workspace, its tab and its terminal: \(created)")
            #expect(created[0].hasPrefix("ws_") && created[1].hasPrefix("tab_") && created[2].hasPrefix("term_"),
                    "the workspace first, then the tab and the terminal: \(created)")
            #expect(!before.contains(created[0]), "the workspace is new: \(created[0]) was listed before the run")

            // The id is the one the snapshot lists, and that workspace holds the tab and the terminal of the run.
            let after = try await workspaces()
            let made = try #require(after.first { $0["id"] == .string(created[0]) }, "no workspace \(created[0]) in the snapshot")
            let tabs = (made["screens"]?.arrayValue ?? []).flatMap { $0.objectValue?["panes"]?.arrayValue ?? [] }
                .flatMap { $0.objectValue?["tabs"]?.arrayValue ?? [] }.compactMap(\.objectValue)
            #expect(tabs.map { $0["id"]?.stringValue } == [created[1]], "\(tabs)")
            #expect(tabs.first?["terminal"] == .string(created[2]), "\(tabs)")
        }
    }
}
