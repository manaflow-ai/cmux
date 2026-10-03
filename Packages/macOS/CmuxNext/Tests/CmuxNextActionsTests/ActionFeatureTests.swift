import AppKit
@testable import CmuxNextActions
import Testing

/// `DisabledFeatures` (spec/enterprise.md 5.2): a turned-off feature's
/// actions leave every surface that runs through the registry.
@MainActor
@Suite struct ActionFeatureTests {
    static func ids(_ feature: ActionFeature) -> Set<String> {
        Set(ActionCatalog.all.filter { ActionFeature.feature(of: $0) == feature }.map(\.id.rawValue))
    }

    /// The rules pick these actions today; a new action of a feature joins
    /// its set by the same rule, and this pins the review of what moved.
    @Test func featuresMapTheirActions() {
        #expect(Self.ids(.computerUse) == ["palette.computerUse.setup", "palette.computerUse.accessibility", "palette.computerUse.screenRecording",
                                           "computerUseFocus", "computerUseFocusCallingTerminal", "computerUseStop"])
        #expect(Self.ids(.apps) == ["appStore.show", "appStore.showInstalled", "app.hide", "app.unhide", "app.open", "app.command.run"])
        #expect(Self.ids(.remoteHosts).isSuperset(of: ["remote.connect", "remote.newWorkspace", "disconnectRemoteTab"]))
        let cloud = Self.ids(.cloud)
        #expect(cloud.contains("newCloudMachine") && cloud.contains("palette.openCloudPane") && cloud.contains("switchRightSidebarToMachines"))
        // Account and sign-in actions stay: turning off Cloud must not lock
        // anyone out of their account.
        for id in ["palette.auth.signIn", "palette.auth.signOut", "accounts.show", "openTeamPicker"] {
            #expect(!cloud.contains(id), "\(id)")
        }
        #expect(Self.ids(.browserAutomation).isEmpty && Self.ids(.mcp).isEmpty)
    }

    @Test func aDisabledFeatureLeavesTheRegistry() throws {
        let registry = ActionRegistry.standard()
        var ran: [ActionID] = []
        registry.bind("newCloudMachine") { ran.append("newCloudMachine") }
        registry.bind("splitRight") { ran.append("splitRight") }
        #expect(registry.isAvailable("newCloudMachine"))

        registry.disabledFeatures = [.cloud]
        #expect(registry.disabledFeature(for: "newCloudMachine") == .cloud)
        #expect(!registry.isAvailable("newCloudMachine"))
        #expect(!registry.canPerform("newCloudMachine"))
        #expect(!registry.perform("newCloudMachine"))
        #expect(registry.perform("splitRight"))
        #expect(ran == ["splitRight"])

        registry.disabledFeatures = []
        #expect(registry.perform("newCloudMachine"))
        #expect(ran == ["splitRight", "newCloudMachine"])
    }

    /// Cmd-Y (New Cloud Machine) stops resolving while Cloud is off.
    @Test func aDisabledFeatureLeavesItsShortcuts() throws {
        let registry = ActionRegistry.standard()
        registry.bind("newCloudMachine") {}
        let shortcut = Shortcut("y", modifiers: [.command])
        #expect(registry.resolve(shortcut)?.id == "newCloudMachine")
        registry.disabledFeatures = [.cloud]
        #expect(registry.resolve(shortcut)?.id != "newCloudMachine")
    }

    @Test func serverActionsAreRemoteHosts() {
        let remote = Self.ids(.remoteHosts)
        // Opening remote access is turned off; stopping a running server stays possible.
        #expect(remote.isSuperset(of: ["server.makeThisMacAServer", "server.addServer"]))
        #expect(!remote.contains("server.stopServing"))
    }

    /// A turned-off feature binds no key or chord, so the leader overlay
    /// and shortcut resolution never reach it; other chords stay.
    @Test func aDisabledFeatureLeavesTheShortcutIndex() throws {
        let registry = ActionRegistry.standard()
        registry.disabledFeatures = Set(ActionFeature.allCases)
        let index = registry.currentShortcutIndex()
        let chorded = index.chords.values.flatMap { $0.values.flatMap { $0 } }
        let keyed = index.byShortcut.values.flatMap { $0 }
        #expect(!chorded.isEmpty && !keyed.isEmpty)
        for id in chorded + keyed { #expect(registry.disabledFeature(for: id) == nil, "\(id)") }
        #expect(!keyed.contains("newCloudMachine"))
    }
}
