import CmuxNextSettings
import Testing

/// `sidebar.showWorkspaceTabs`: on a fresh profile workspace rows list no tabs beneath them (the
/// sidebar before f32ee25f5a51 turned it on by default). The user can turn it on in cmux.json or
/// Settings, and a bad value keeps the default with a diagnostic.
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

    @Test func theUserCanListEveryWorkspacesTabs() {
        #expect(Self.parse(.bool(true)).sidebarSections.showWorkspaceTabs)
        #expect(Self.parse(.bool(false)).sidebarSections.showWorkspaceTabs == false)
    }

    @Test func aBadValueKeepsTheDefaultWithADiagnostic() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.sidebarSections.showWorkspaceTabs == false)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.showWorkspaceTabs" }, "\(snapshot.diagnostics)")
    }
}
