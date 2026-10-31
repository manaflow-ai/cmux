import CmuxNextDesign
import CmuxNextSettings
import Testing

/// Lawrence 2026-10-20: group hover cards are "fully customizable": `sidebar.hoverCards.groups.*`
/// turns them on per kind, sets their delay, which part leads, how many members they name and
/// which parts show. Settings rows, cmux.json, the palette's settings rows and `cmux settings set`
/// (CLI and MCP) all read the same schema rows.
struct GroupHoverCardSettingsTests {
    static let paths = [
        HoverCardSettings.groupsWorkspaceGroupsPath, HoverCardSettings.groupsTabGroupsPath,
        HoverCardSettings.groupsSectionStatusPath, HoverCardSettings.groupsSectionMembersPath,
        HoverCardSettings.groupsSectionActivityPath, HoverCardSettings.groupsSectionGitPath,
        HoverCardSettings.groupsSectionPortsPath,
    ]

    @Test func defaultsShowEveryPartOnBothKindsAfterALongerDelay() throws {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        let options = snapshot.hoverCards.groupCardOptions
        #expect(options == GroupHoverCardOptions())
        #expect(options.workspaceGroups && options.tabGroups)
        #expect(options.delay == .milliseconds(1500))
        #expect(options.sections == [.status, .members, .activity, .git, .ports])
        for path in Self.paths {
            let row = try #require(SettingsSchema.descriptor(for: path), "no Settings row for \(path)")
            #expect(row.kind == .toggle)
            #expect(row.defaultValue == .bool(true))
        }
        #expect(SettingsSchema.descriptor(for: HoverCardSettings.groupsDelayPath)?.defaultValue == .number(1500))
        #expect(SettingsSchema.descriptor(for: HoverCardSettings.groupsOrderPath)?.defaultValue == .string("status"))
        #expect(SettingsSchema.descriptor(for: HoverCardSettings.groupsMaxMembersPath)?.defaultValue == .number(8))
    }

    @Test func cmuxJSONCustomizesTheGroupCards() {
        let root = JSONValue.object(["sidebar": .object(["hoverCards": .object(["groups": .object([
            "tabGroups": .bool(false),
            "delay": .number(1200),
            "order": .string("activity"),
            "maxMembers": .number(4),
            "sections": .object(["git": .bool(false), "ports": .bool(false)]),
        ])])])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        let options = snapshot.hoverCards.groupCardOptions
        #expect(options.workspaceGroups)
        #expect(!options.tabGroups)
        #expect(options.delay == .milliseconds(1200))
        #expect(options.order == .activity)
        #expect(options.maxMembers == 4)
        #expect(options.sections == [.activity, .status, .members])
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test func aBadOrderKeepsTheDefaultWithADiagnostic() {
        let root = JSONValue.object(["sidebar": .object(["hoverCards": .object(["groups": .object(["order": .string("random")])])])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.hoverCards.groupCardOptions.order == .status)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.hoverCards.groups.order" })
    }
}
