import CmuxNextDesignTokens
import CmuxNextSettings
import Foundation
import Testing

/// cmux.json `workspaceGroups` (docs/workspace-groups.md): a group's entry is found by its anchor's
/// folder (a folder key matches it and every folder inside; a glob matches the whole path; the
/// longest key wins), and each member is read with a diagnostic for a bad value.
struct WorkspaceGroupConfigTests {
    static let home = "/Users/you"

    static func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func anEntryHoldsTheGroupsSettings() throws {
        let snapshot = try Self.parse("""
        {"workspaceGroups": {"newWorkspacePlacement": "top", "byCwd": {
          "~/manaflow/cmux": {"color": "#7A4FD8", "icon": "ladybug.fill", "newWorkspacePlacement": "end",
                              "contextMenu": [{"action": "newWorktree", "title": "New Worktree"}, {"action": "newWorkspace"}]}
        }}}
        """)
        let config = snapshot.workspaceGroups
        #expect(config.newWorkspacePlacement == .top)
        let entry = try #require(config.entry(for: "\(Self.home)/manaflow/cmux", home: Self.home))
        #expect(entry.key == "~/manaflow/cmux")
        #expect(entry.entry.color == GroupTint(wire: "#7A4FD8"))
        #expect(entry.entry.icon == "ladybug.fill")
        #expect(entry.entry.newWorkspacePlacement == .end)
        #expect(entry.entry.contextMenu == [.init(action: "newWorktree", title: "New Worktree"), .init(action: "newWorkspace")])
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("workspaceGroups") })
    }

    @Test func aFolderKeyMatchesItsSubfoldersAndTheLongestKeyWins() throws {
        let config = try Self.parse("""
        {"workspaceGroups": {"byCwd": {"~/projects": {"icon": "a"}, "~/projects/cmux": {"icon": "b"}, "~/projects/c*": {"icon": "c"}}}}
        """).workspaceGroups
        #expect(config.entry(for: "\(Self.home)/projects/cmux/web", home: Self.home)?.key == "~/projects/cmux")
        #expect(config.entry(for: "\(Self.home)/projects/cli", home: Self.home)?.key == "~/projects/c*")
        #expect(config.entry(for: "\(Self.home)/projects/other", home: Self.home)?.key == "~/projects")
        #expect(config.entry(for: "\(Self.home)/projectsX", home: Self.home) == nil, "a folder key is not a string prefix")
        #expect(config.entry(for: nil, home: Self.home) == nil)
    }

    @Test func placementFallsBackToTheGlobalThenTheEnd() throws {
        let config = try Self.parse("""
        {"workspaceGroups": {"byCwd": {"/work/a": {"newWorkspacePlacement": "top"}, "/work/b": {}}}}
        """).workspaceGroups
        #expect(config.placement(for: "/work/a") == .top)
        #expect(config.placement(for: "/work/b") == .end, "unset: after the group's last workspace, as before")
        var global = config
        global.newWorkspacePlacement = .afterCurrent
        #expect(global.placement(for: "/work/b") == .afterCurrent)
    }

    @Test func badValuesAreDroppedWithADiagnostic() throws {
        let snapshot = try Self.parse("""
        {"workspaceGroups": {"newWorkspacePlacement": "middle", "byCwd": {"/w": {"color": "plaid", "icon": "x", "contextMenu": [{"title": "no action"}]}}}}
        """)
        let entry = try #require(snapshot.workspaceGroups.byCwd["/w"])
        #expect(entry.color == nil)
        #expect(entry.icon == "x", "the rest of the entry stays")
        #expect(entry.contextMenu.isEmpty)
        let paths = Set(snapshot.diagnostics.map(\.path))
        #expect(paths.contains("workspaceGroups.newWorkspacePlacement"))
        #expect(paths.contains("workspaceGroups.byCwd./w.color"))
        #expect(paths.contains("workspaceGroups.byCwd./w.contextMenu.0"))
    }

    @Test func aNewEntrysKeyWritesTheHomeFolderAsTilde() {
        #expect(WorkspaceGroupConfig.key(for: "\(Self.home)/manaflow/cmux/", home: Self.home) == "~/manaflow/cmux")
        #expect(WorkspaceGroupConfig.key(for: "/opt/work", home: Self.home) == "/opt/work")
    }

    /// Edit Group Config opens the file at the group's entry: the line and column of its key.
    @Test func aMembersPositionIsItsKeysLineAndColumn() {
        let source = "{\n  // groups\n  \"workspaceGroups\": {\n    \"byCwd\": {\n      \"~/w\": {}\n    }\n  }\n}\n"
        let position = JSONC.position(of: ["workspaceGroups", "byCwd", "~/w"], in: source)
        #expect(position?.line == 5)
        #expect(position?.column == 7)
        #expect(JSONC.position(of: ["workspaceGroups", "byCwd", "~/none"], in: source) == nil)
    }
}
