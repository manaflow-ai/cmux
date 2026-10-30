import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar
import Foundation
import Testing

@MainActor @Suite(.serialized)
struct CloudNewWorkspaceEntryTests {
    @Test func sidebarPlusRunsTheSameUserActionAsCommandNInItsOwnWindow() throws {
        let services = MachineIconTests.services()
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"cloud-plus","workspace_key":"plus-home"}"#.utf8))
        let state = WindowState(record: record)
        let bridge = SidebarBridge(services: services, state: state)
        var calls: [ActionInvocation] = []
        let bound = services.registry.bind("newTab", invoke: { calls.append($0) })
        #expect(bound)
        bridge.handle(.newWorkspace(machine: nil, group: nil))
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.origin == .user)
        #expect(call.target == ActionTargetRef(kind: .window, id: state.id))
    }

    @Test func sidebarPlusInARemoteMachinesWindowStaysOnThatMachine() throws {
        let services = MachineIconTests.services()
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"cloud-plus-remote","workspace_key":"plus-remote"}"#.utf8))
        let state = WindowState(record: record)
        state.machineID = "vm-plus-remote"
        let bridge = SidebarBridge(services: services, state: state)
        var calls: [ActionInvocation] = []
        let bound = services.registry.bind("newTab", invoke: { calls.append($0) })
        #expect(bound)
        bridge.handle(.newWorkspace(machine: nil, group: nil))
        // Cmd-N's route makes it on this Mac; this window's machine (here gone) keeps it there or makes nothing.
        #expect(calls.isEmpty)
    }

    /// Services whose cmux.json is `json`, as the app reads it.
    static func services(settings json: String) async throws -> AppServices {
        let services = MachineIconTests.services()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-new-ws-entry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        return services
    }

    /// A paid machine is asked for only where it shows: Cmd-N with every window closed (no window
    /// to show progress, Cancel or Retry in) asks Cloud for nothing and says the workspace opened here.
    @Test func withNoOpenWindowTheToggleAsksForNoMachineAndSaysSo() async throws {
        let services = try await Self.services(settings: #"{"cloud":{"newWorkspacesInCloud":true}}"#)
        let route = CloudHandlers.startNewWorkspaceInCloud(ActionInvocation(origin: .user), cwd: nil, window: nil, services)
        guard case .thisMac(let notice) = route else { Issue.record("a creation started with no window: \(route)"); return }
        #expect(notice?.isEmpty == false, "the person is told why the workspace is not in Cloud")
        #expect(services.cloud.creations.all.isEmpty, "no creation, so no provider call")
    }

    /// Signed out (or Cloud unavailable in this build): New Workspace opens here, saying why, not silently.
    @Test func whenCloudCannotCreateTheWorkspaceOpensHereAndSaysWhy() async throws {
        let services = try await Self.services(settings: #"{"cloud":{"newWorkspacesInCloud":true}}"#)
        #expect(!services.cloud.isSignedIn)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"cloud-signed-out","workspace_key":"signed-out"}"#.utf8))
        let route = CloudHandlers.startNewWorkspaceInCloud(ActionInvocation(origin: .user), cwd: nil, window: WindowState(record: record), services)
        guard case .thisMac(let notice) = route else { Issue.record("a creation started while signed out: \(route)"); return }
        #expect(notice?.isEmpty == false)
        #expect(services.cloud.creations.all.isEmpty)
    }

    /// With the toggle off nothing changes: no notice, no creation.
    @Test func withTheToggleOffNewWorkspaceSaysNothing() async throws {
        let services = try await Self.services(settings: "{}")
        let route = CloudHandlers.startNewWorkspaceInCloud(ActionInvocation(origin: .user), cwd: nil, window: nil, services)
        #expect(route == .thisMac(notice: nil))
        #expect(services.cloud.creations.all.isEmpty)
    }
}
