@testable import CmuxNextSettings
import Testing

/// `sidebar.workspaceListApp`: unset, null, empty or blank draws the built-in workspace list (the
/// default); an app id names the extension that draws it; a non-string is the default plus a
/// diagnostic naming the key.
struct SidebarWorkspaceListAppSettingTests {
    private static func app(_ value: JSONValue?) -> (String?, [SettingsDiagnostic]) {
        let root: JSONValue = value.map { .object(["sidebar": .object(["workspaceListApp": $0])]) } ?? .object([:])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        return (snapshot.sidebarSections.workspaceListApp, snapshot.diagnostics.filter { $0.path == "sidebar.workspaceListApp" })
    }

    @Test func theBuiltInListIsTheDefault() {
        for value: JSONValue? in [nil, .null, .string(""), .string("  ")] {
            let (app, diagnostics) = Self.app(value)
            #expect(app == nil)
            #expect(diagnostics.isEmpty)
        }
    }

    @Test func anAppIdNamesTheExtension() {
        let (app, diagnostics) = Self.app(.string("local/workspace-list"))
        #expect(app == "local/workspace-list")
        #expect(diagnostics.isEmpty)
    }

    @Test func aNonStringKeepsTheBuiltInListWithADiagnostic() {
        let (app, diagnostics) = Self.app(.bool(true))
        #expect(app == nil)
        #expect(diagnostics.count == 1)
    }
}
