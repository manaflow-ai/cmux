import CmuxNextSettings
import Testing

/// `sidebar.showWorkspaceTabs` (https://github.com/manaflow-ai/cmux/issues/28604): off by default, so
/// a profile that never set it (fresh or existing) shows workspaces without their tab rows. The user
/// can turn it on in cmux.json or Settings, and a bad value keeps the default with a diagnostic.
struct SidebarShowWorkspaceTabsDefaultTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["showWorkspaceTabs": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.showWorkspaceTabs == false)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanListOrHideEveryWorkspaceTabs() {
        #expect(Self.parse(.bool(false)).sidebarSections.showWorkspaceTabs == false)
        #expect(Self.parse(.bool(true)).sidebarSections.showWorkspaceTabs)
    }

    @Test func aBadValueKeepsTheDefaultWithADiagnostic() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.sidebarSections.showWorkspaceTabs == false)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.showWorkspaceTabs" }, "\(snapshot.diagnostics)")
    }
}
