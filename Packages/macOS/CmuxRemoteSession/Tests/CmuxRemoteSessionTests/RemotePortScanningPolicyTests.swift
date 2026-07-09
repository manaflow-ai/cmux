import Foundation
import Testing
import CmuxSettings
@testable import CmuxRemoteSession

// Pins the settings-derivation precedence the backend ssh port-scan loop uses
// (issue #6123): `sidebar.hideAllDetails` wins over `sidebar.showPorts`, so the
// scan only runs when ports are actually displayed in the sidebar. Lifted from
// `Workspace.remotePortScanningEnabledFromSettings(defaults:)`; this test drives
// the policy against a suite-scoped `UserDefaults` so it never touches the real
// defaults domain.
@Suite("Remote port scanning settings policy")
struct RemotePortScanningPolicyTests {
    private func scopedDefaults() -> UserDefaults {
        let suite = "cmux.tests.remote-port-scanning.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Shows ports and details visible: enabled")
    func showsPortsDetailsVisible() {
        let defaults = scopedDefaults()
        defaults.set(true, forKey: "sidebarShowPorts")
        defaults.set(false, forKey: "sidebarHideAllDetails")
        #expect(RemotePortScanningPolicy().isEnabled(defaults: defaults) == true)
    }

    @Test("hideAllDetails wins over showPorts: disabled")
    func hideAllDetailsWins() {
        let defaults = scopedDefaults()
        defaults.set(true, forKey: "sidebarShowPorts")
        defaults.set(true, forKey: "sidebarHideAllDetails")
        #expect(RemotePortScanningPolicy().isEnabled(defaults: defaults) == false)
    }

    @Test("Ports hidden: disabled")
    func portsHidden() {
        let defaults = scopedDefaults()
        defaults.set(false, forKey: "sidebarShowPorts")
        defaults.set(false, forKey: "sidebarHideAllDetails")
        #expect(RemotePortScanningPolicy().isEnabled(defaults: defaults) == false)
    }
}
