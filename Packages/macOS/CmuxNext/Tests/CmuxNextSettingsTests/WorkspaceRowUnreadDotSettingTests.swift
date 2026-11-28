import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `sidebar.workspaceRow.unreadDot`: `blue` (the default, today's rows) or `neutral` (a gray dot in
/// the theme's secondary text color, the Claude Code app's session list; customize-app-profiles).
struct WorkspaceRowUnreadDotSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let row: JSONValue = value.map { .object(["unreadDot": $0]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(.object(["sidebar": .object(["workspaceRow": row])]), validDensities: [], validMetrics: [])
    }

    @Test func blueWhenUnset() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.workspaceRow.unreadDot == .blue)
        #expect(snapshot.sidebarSections.workspaceRow == WorkspaceRowPreferences.defaults)
        #expect(WorkspaceRowPreferences.defaults.unreadDot == WorkspaceRowSetting.unreadDotDefault)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func blueAndNeutralParse() {
        #expect(Self.parse(.string("neutral")).sidebarSections.workspaceRow.unreadDot == .neutral)
        #expect(Self.parse(.string("blue")).sidebarSections.workspaceRow.unreadDot == .blue)
        #expect(Self.parse(.string("neutral")).diagnostics.isEmpty)
    }

    @Test func aBadValueKeepsBlueAndSaysWhy() {
        let snapshot = Self.parse(.string("purple"))
        #expect(snapshot.sidebarSections.workspaceRow.unreadDot == .blue)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.workspaceRow.unreadDot" })
    }

    @Test func theSettingsRowOffersBothAndDefaultsToBlue() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["sidebar", "workspaceRow", "unreadDot"]))
        #expect(row.defaultValue == .string("blue"))
        guard case .choice(let choices) = row.kind else {
            Issue.record("not a choice row: \(row.kind)")
            return
        }
        #expect(choices.map(\.value) == WorkspaceRowUnreadDot.allCases.map(\.rawValue))
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar.workspaceRow.unreadDot"))
    }
}
