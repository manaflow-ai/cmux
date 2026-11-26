import CmuxNextPages
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextSidebarActions
import Foundation
import Testing

/// Settings > Sidebar > Archived Workspaces (cmux#51635): the page's list and its Open, Restore and Delete reach the
/// host only for a row the list shows, and only from the Settings page.
@MainActor @Suite struct SettingsArchivedWorkspacesTests {
    static let rows = [
        SidebarArchivedEntry(kind: .workspace, id: "ws-1", title: "Old fix", group: "Docs", machine: "This Mac"),
        SidebarArchivedEntry(kind: .item, id: "itm-1", title: "Design review"),
    ]
    static let settings = PageCallContext(page: PageDescriptor.settings.id, userGesture: true)

    final class Ran { var runs: [(SettingsArchivedWorkspaces.Action, SidebarArchivedEntry)] = [] }

    static func part(_ rows: [SidebarArchivedEntry]? = rows, refusal: String? = nil, ran: Ran = Ran()) -> SettingsArchivedWorkspaces {
        SettingsArchivedWorkspaces(host: .init(entries: { rows }, run: { action, entry in
            ran.runs.append((action, entry))
            return refusal
        }), personOnly: "only a person")
    }

    @Test func theListAnswersEachRowWithItsKindGroupAndComputer() async throws {
        let answer = try await Self.part().call(SettingsArchivedWorkspaces.listOp, params: .object([:]), context: Self.settings)
        #expect(answer["available"] == .bool(true))
        let rows = try #require(answer["rows"]?.arrayValue)
        #expect(rows.count == 2)
        #expect(rows[0]["kind"] == .string("workspace") && rows[0]["id"] == .string("ws-1"))
        #expect(rows[0]["group"] == .string("Docs") && rows[0]["machine"] == .string("This Mac"))
        #expect(rows[1]["kind"] == .string("item") && rows[1]["group"] == .null)
    }

    @Test func noWindowAnswersUnavailable() async throws {
        let answer = try await Self.part(nil).call(SettingsArchivedWorkspaces.listOp, params: .object([:]), context: Self.settings)
        #expect(answer["available"] == .bool(false))
    }

    @Test func eachActionRunsOnTheListedRow() async throws {
        let ran = Ran()
        let part = Self.part(ran: ran)
        for action in ["open", "restore", "delete"] {
            let answer = try await part.call(SettingsArchivedWorkspaces.runOp,
                                             params: ["action": .string(action), "kind": "workspace", "id": "ws-1"], context: Self.settings)
            #expect(answer == .object([:]))
        }
        #expect(ran.runs.map(\.0) == [.open, .restore, .delete])
        #expect(ran.runs.allSatisfy { $0.1 == Self.rows[0] })
    }

    @Test func aRefusalComesBackAsTheRowsError() async throws {
        let answer = try await Self.part(refusal: "nope").call(SettingsArchivedWorkspaces.runOp,
                                                               params: ["action": "delete", "kind": "item", "id": "itm-1"], context: Self.settings)
        #expect(answer["error"] == .string("nope"))
    }

    /// The page names only a listed row: a live workspace's id, or the right id with the wrong kind, runs nothing.
    @Test func anUnlistedRowRunsNothing() async {
        let ran = Ran()
        let part = Self.part(ran: ran)
        for params: JSONValue in [["action": "delete", "kind": "workspace", "id": "live-ws"],
                                  ["action": "delete", "kind": "item", "id": "ws-1"],
                                  ["action": "explode", "kind": "workspace", "id": "ws-1"]] {
            await #expect(throws: PageError.self) { _ = try await part.call(SettingsArchivedWorkspaces.runOp, params: params, context: Self.settings) }
        }
        #expect(ran.runs.isEmpty)
    }

    @Test func onlyTheSettingsPageRunsThem() async {
        let ran = Ran()
        await #expect(throws: PageError.self) {
            _ = try await Self.part(ran: ran).call(SettingsArchivedWorkspaces.runOp, params: ["action": "delete", "kind": "workspace", "id": "ws-1"],
                                                   context: PageCallContext(page: "cmux.history", userGesture: true))
        }
        #expect(ran.runs.isEmpty)
    }

    /// A script in the Settings page itself (no click, no confirmed person) runs nothing either.
    @Test func aScriptInSettingsRunsNothing() async {
        let ran = Ran()
        await #expect(throws: PageError.self) {
            _ = try await Self.part(ran: ran).call(SettingsArchivedWorkspaces.runOp, params: ["action": "delete", "kind": "workspace", "id": "ws-1"],
                                                   context: PageCallContext(page: PageDescriptor.settings.id))
        }
        #expect(ran.runs.isEmpty)
    }
}
