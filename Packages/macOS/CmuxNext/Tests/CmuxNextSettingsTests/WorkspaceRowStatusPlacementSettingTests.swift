import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `sidebar.workspaceRow.statusPlacement`: `trailing` (the default, today's rows) or `leading`
/// (the status mark before the title, a minimal session list). One value for every kind.
struct WorkspaceRowStatusPlacementSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let row: JSONValue = value.map { .object(["statusPlacement": $0]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(.object(["sidebar": .object(["workspaceRow": row])]), validDensities: [], validMetrics: [])
    }

    @Test func trailingWhenUnset() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.workspaceRow.statusPlacement == .trailing)
        #expect(snapshot.sidebarSections.workspaceRow == WorkspaceRowPreferences.defaults)
        #expect(WorkspaceRowPreferences.defaults.statusPlacement == WorkspaceRowSetting.statusPlacementDefault)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func leadingAndTrailingParse() {
        #expect(Self.parse(.string("leading")).sidebarSections.workspaceRow.statusPlacement == .leading)
        #expect(Self.parse(.string("trailing")).sidebarSections.workspaceRow.statusPlacement == .trailing)
        #expect(Self.parse(.string("leading")).diagnostics.isEmpty)
    }

    @Test func aBadValueKeepsTrailingAndSaysWhy() {
        let snapshot = Self.parse(.string("middle"))
        #expect(snapshot.sidebarSections.workspaceRow.statusPlacement == .trailing)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.workspaceRow.statusPlacement" })
    }

    @Test func theSettingsRowOffersBothAndDefaultsToTrailing() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["sidebar", "workspaceRow", "statusPlacement"]))
        #expect(row.defaultValue == .string("trailing"))
        guard case .choice(let choices) = row.kind else {
            Issue.record("not a choice row: \(row.kind)")
            return
        }
        #expect(choices.map(\.value) == WorkspaceRowStatusPlacement.allCases.map(\.rawValue))
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar.workspaceRow.statusPlacement"))
    }
}
