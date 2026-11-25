import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceDetailViewBrowserRouteTests {
    @Test func siblingInstancesKeepSeparateBrowserRoutesAndWebsiteData() throws {
        let deviceID = UUID().uuidString
        let fixture = try Fixture()
        defer { fixture.cleanDefaults() }
        let store = fixture.store
        let stable = detail(store: store, macDeviceID: deviceID, instanceTag: "stable")
        let nightly = detail(store: store, macDeviceID: deviceID, instanceTag: "nightly")
        let stableRoute = try #require(stable.macBrowserRoute)
        let nightlyRoute = try #require(nightly.macBrowserRoute)
        #expect(stableRoute !== nightlyRoute)
        #expect(stableRoute.dataStore !== nightlyRoute.dataStore)
        #expect(stableRoute === stable.macBrowserRoute)

        let alternate = detail(store: store, macDeviceID: deviceID.lowercased(), instanceTag: " stable ")
        #expect(stableRoute === alternate.macBrowserRoute)
    }

    @Test func legacyWorkspaceDoesNotAdoptTheForegroundInstancesTag() throws {
        let fixture = try Fixture()
        defer { fixture.cleanDefaults() }
        let store = fixture.store
        store.connectionState = .connected
        store.foregroundMacDeviceID = "mac-a"
        store.activeMacInstanceTag = "nightly"
        let legacy = detail(store: store, macDeviceID: "mac-a", instanceTag: nil)
        let legacyKey = try #require(legacy.browserTunnelMacKey)
        #expect(legacyKey == MacPairingKey(macDeviceID: "mac-a", instanceTag: nil))
        #expect(store.macBrowserTunnelAvailability(pairingKey: legacyKey) == .notConnected)
        #expect(legacy.macBrowserRoute?.id == "mac:mac-a")
    }

    @Test func workspaceWithoutIdentityUsesBothForegroundIdentityFields() throws {
        let fixture = try Fixture()
        defer { fixture.cleanDefaults() }
        let store = fixture.store
        store.connectionState = .connected
        store.foregroundMacDeviceID = "mac-a"
        store.activeMacInstanceTag = "nightly"
        let unscoped = detail(store: store, macDeviceID: nil, instanceTag: nil)
        #expect(unscoped.browserTunnelMacKey == MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly"))
        store.connectionState = .disconnected
        #expect(unscoped.browserTunnelMacKey == nil)
        #expect(unscoped.macBrowserRoute == nil)
    }

    private func detail(store: MobileShellComposite, macDeviceID: String?, instanceTag: String?) -> WorkspaceDetailView {
        var workspace = MobileWorkspacePreview(id: "workspace-a", macDeviceID: macDeviceID, name: "Workspace", terminals: [])
        workspace.macInstanceTag = instanceTag
        return WorkspaceDetailView(
            connectionStatus: .connected,
            workspace: workspace,
            store: store,
            createWorkspace: {},
            canCreateWorkspace: false,
            createTerminal: {},
            renameWorkspace: nil,
            customizeWorkspace: nil,
            setWorkspaceUnread: nil,
            closeWorkspace: nil,
            reportTerminalViewport: { _, _, _ in },
            sendTerminalInput: { _ in },
            safeAreaContext: .fullWidth,
            backButtonConfiguration: nil,
            signOut: nil
        )
    }

    @MainActor private struct Fixture {
        let store: MobileShellComposite
        let suiteName = "cmux-browser-route-\(UUID().uuidString)"
        let defaults: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suiteName))
            store = MobileShellComposite(
                clientIDRepository: MobileClientIDRepository(defaults: defaults),
                pairingHintDefaults: defaults,
                multiMacAggregationDefaults: defaults
            )
        }

        func cleanDefaults() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
