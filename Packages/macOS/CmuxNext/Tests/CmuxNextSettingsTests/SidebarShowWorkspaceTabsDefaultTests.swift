import CmuxNextSettings
import Testing

/// `sidebar.showWorkspaceTabs` (Lawrence 2026-10-27: "show everything by default"): on a fresh
/// profile every workspace lists its tabs in the sidebar. The user can turn it off in cmux.json or
/// Settings, and a bad value keeps the default with a diagnostic.
struct SidebarShowWorkspaceTabsDefaultTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["showWorkspaceTabs": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func onByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.showWorkspaceTabs)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanHideEveryWorkspaceTabs() {
        #expect(Self.parse(.bool(false)).sidebarSections.showWorkspaceTabs == false)
        #expect(Self.parse(.bool(true)).sidebarSections.showWorkspaceTabs)
    }

    @Test func aBadValueKeepsTheDefaultWithADiagnostic() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.sidebarSections.showWorkspaceTabs)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.showWorkspaceTabs" }, "\(snapshot.diagnostics)")
    }
}
