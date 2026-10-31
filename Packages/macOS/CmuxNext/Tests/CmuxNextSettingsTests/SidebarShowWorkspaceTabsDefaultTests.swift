import CmuxNextSettings
import Testing

/// `sidebar.showWorkspaceTabs` (#26384): on a fresh profile the sidebar lists plain workspace
/// rows, no tabs or panes under them. The user can turn it on in cmux.json or Settings, and a bad
/// value keeps the default with a diagnostic.
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

    /// An existing user who never chose: their settings file has other sidebar keys but not this one (cmux.json stores
    /// only what the user set), so they read off too, also after f32ee25f5a51 (on by default, 2026-10-26..30) was
    /// taken back by #26402. Lawrence 2026-10-31: "show tabs under workspaces should never be on by default".
    @Test func anExistingUserWhoNeverChoseReadsOff() {
        let root: JSONValue = .object(["sidebar": .object([
            "density": .string("compact"), "minimal": .bool(false), "showSpaces": .bool(true),
        ])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.sidebarSections.showWorkspaceTabs == false)
        #expect(CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []).sidebarSections.showWorkspaceTabs == false,
                "the built-in default")
    }

    @Test func theUserCanListEveryWorkspaceTabs() {
        #expect(Self.parse(.bool(true)).sidebarSections.showWorkspaceTabs)
        #expect(Self.parse(.bool(false)).sidebarSections.showWorkspaceTabs == false)
    }

    @Test func aBadValueKeepsTheDefaultWithADiagnostic() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.sidebarSections.showWorkspaceTabs == false)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.showWorkspaceTabs" }, "\(snapshot.diagnostics)")
    }
}
