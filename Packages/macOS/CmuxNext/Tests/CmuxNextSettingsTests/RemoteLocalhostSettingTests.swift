import Testing
@testable import CmuxNextSettings

struct RemoteLocalhostSettingTests {
    func parse(_ text: String) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try! JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func onByDefault() {
        let snapshot = parse("{}")
        #expect(snapshot.remoteLocalhost == .fallback)
        #expect(snapshot.remoteLocalhost.isEnabled(workspace: "w1"))
    }

    @Test func offSwitchAndWorkspaceOverrides() {
        let snapshot = parse(#"{"browser": {"remoteLocalhost": false, "remoteLocalhostWorkspaces": {"w2": true}}}"#)
        #expect(!snapshot.remoteLocalhost.isEnabled(workspace: "w1"))
        #expect(snapshot.remoteLocalhost.isEnabled(workspace: "w2"))
        #expect(!snapshot.remoteLocalhost.isEnabled(workspace: nil))
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func badValuesKeepTheDefaultAndReport() {
        let snapshot = parse(#"{"browser": {"remoteLocalhost": "yes", "remoteLocalhostWorkspaces": {"w1": 1}}}"#)
        #expect(snapshot.remoteLocalhost.enabled)
        #expect(snapshot.remoteLocalhost.workspaceOverrides.isEmpty)
        #expect(snapshot.diagnostics.map(\.path).contains("browser.remoteLocalhost"))
        #expect(snapshot.diagnostics.map(\.path).contains("browser.remoteLocalhostWorkspaces.w1"))
    }
}
