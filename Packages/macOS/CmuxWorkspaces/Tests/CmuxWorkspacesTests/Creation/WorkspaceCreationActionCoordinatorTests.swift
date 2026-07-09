import Foundation
import Testing
import CmuxSettings
import CmuxWindowing
@testable import CmuxWorkspaces

/// Records the host calls and returns scripted values so the coordinator's
/// routing decisions can be asserted on the call sequence and return.
@MainActor
private final class FakeActionHost: WorkspaceCreationActionHosting {
    typealias SelectionContext = String

    // Scripted inputs.
    var livePreferredWindow: WindowID?
    var preferredCreationWindow: WindowID?
    var cloudVMWindow: WindowID?
    var remoteHandled = false
    var browserEnabled = true
    var membership: WorkspaceGroupMembership?
    var configuredPlacement: WorkspaceGroupNewPlacement?
    var defaultPlacement: WorkspaceGroupNewPlacement = .end
    var preferredManagerPresent = false
    var preferredManagerHasNoContext = false
    var configuredActionRuns = false
    var createdWorkspaceId = UUID()
    var workspaceCountValue = 1
    var containsValue = true
    var selectedIdValue: UUID?
    var cloudVMStarts = true

    // Recorded effects.
    private(set) var calls: [String] = []
    private(set) var closedWorkspaceIds: [UUID] = []
    private(set) var focusedBrowserIds: [UUID] = []
    private(set) var createdMainWindows = 0
    private(set) var openedNewWindows = 0
    private(set) var beeps = 0

    func livePreferredWindowToken(for selector: SelectionContext) -> WindowID? { livePreferredWindow }
    var hasNoMainWindows: Bool { _hasNoMainWindows }
    private var _hasNoMainWindows = false

    func preferredWindowTokenForCreation(selector: SelectionContext, debugSource: String) -> WindowID? {
        calls.append("preferredWindowTokenForCreation")
        return preferredCreationWindow
    }
    func windowTokenForCloudVM(selector: SelectionContext, debugSource: String) -> WindowID? { cloudVMWindow }
    func createMainWindowToken() -> WindowID {
        createdMainWindows += 1
        let id = WindowID(UUID())
        calls.append("createMainWindow")
        return id
    }
    func openNewMainWindow() { openedNewWindows += 1; calls.append("openNewMainWindow") }
    func logFallbackNewWindow(selector: SelectionContext, source: String, reason: String) {
        calls.append("logFallbackNewWindow:\(reason)")
    }
    func selectedWorkspaceId(in windowToken: WindowID) -> UUID? { selectedIdValue }
    func addWorkspace(in windowToken: WindowID, initialSurface: NewWorkspaceInitialSurface) -> UUID? {
        calls.append("addWorkspace:\(initialSurface)")
        return createdWorkspaceId
    }
    func hasPreferredTabManager(selector: SelectionContext) -> Bool { preferredManagerPresent }
    func preferredTabManagerHasNoMainWindowContext(selector: SelectionContext) -> Bool { preferredManagerHasNoContext }
    func addWorkspaceToPreferredTabManager(selector: SelectionContext, initialSurface: NewWorkspaceInitialSurface) -> UUID? {
        calls.append("addWorkspaceToPreferredTabManager:\(initialSurface)")
        return createdWorkspaceId
    }
    func createWorkspaceInGroup(in windowToken: WindowID, target: WorkspaceGroupNewWorkspaceTarget, initialSurface: NewWorkspaceInitialSurface) -> UUID? {
        calls.append("createWorkspaceInGroup:\(target.placement.rawValue):\(initialSurface)")
        return createdWorkspaceId
    }
    func addWorkspaceInPreferredMainWindow(selector: SelectionContext, initialSurface: NewWorkspaceInitialSurface, debugSource: String) -> UUID? {
        calls.append("addWorkspaceInPreferredMainWindow:\(initialSurface)")
        return createdWorkspaceId
    }
    func focusInitialBrowserAddressBar(workspaceId: UUID) { focusedBrowserIds.append(workspaceId) }
    func workspaceCount(in windowToken: WindowID) -> Int { workspaceCountValue }
    func containsWorkspace(_ workspaceId: UUID, in windowToken: WindowID) -> Bool { containsValue }
    func closeWorkspace(_ workspaceId: UUID, in windowToken: WindowID) { closedWorkspaceIds.append(workspaceId) }
    func handleRemoteWindowNewWorkspaceRequested(in windowToken: WindowID) -> Bool { remoteHandled }
    var isBrowserEnabled: Bool { browserEnabled }
    func beep() { beeps += 1 }
    func beepBrowserDisabled(source: String) { beeps += 1; calls.append("beepBrowserDisabled") }
    func selectedWorkspaceGroupMembership(in windowToken: WindowID) -> WorkspaceGroupMembership? { membership }
    func configuredWorkspaceGroupNewPlacement(in windowToken: WindowID, anchorCwd: String?) -> WorkspaceGroupNewPlacement? { configuredPlacement }
    var defaultWorkspaceGroupNewPlacement: WorkspaceGroupNewPlacement { defaultPlacement }
    func executeConfiguredNewWorkspaceActionIfAvailable(in windowToken: WindowID, debugSource: String, replacingInitialWorkspaceId: UUID?, target: WorkspaceGroupNewWorkspaceTarget?) -> Bool {
        calls.append("executeConfiguredAction")
        return configuredActionRuns
    }
    func startCloudVM(in windowToken: WindowID, selector: SelectionContext, onCompletion: ((CloudVMActionCompletion) -> Void)?) -> Bool {
        calls.append("startCloudVM")
        return cloudVMStarts
    }

    func setHasNoMainWindows(_ v: Bool) { _hasNoMainWindows = v }
}

@MainActor
@Suite("WorkspaceCreationActionCoordinator")
struct WorkspaceCreationActionCoordinatorTests {
    private func makeCoordinator() -> (WorkspaceCreationActionCoordinator<FakeActionHost>, FakeActionHost) {
        let host = FakeActionHost()
        return (WorkspaceCreationActionCoordinator(host: host), host)
    }

    @Test("No main windows and no live preferred falls back to a fresh window for terminal")
    func noWindowTerminalFallback() {
        let (coord, host) = makeCoordinator()
        host.setHasNoMainWindows(true)
        host.livePreferredWindow = nil

        let result = coord.performNewWorkspaceAction(selector: "s", debugSource: "test")

        #expect(result == true)
        #expect(host.createdMainWindows == 1)
        #expect(host.calls.contains("logFallbackNewWindow:no_main_windows"))
        #expect(host.calls.contains("executeConfiguredAction"))
    }

    @Test("No main windows browser path adds browser, closes initial, focuses address bar")
    func noWindowBrowserFallback() {
        let (coord, host) = makeCoordinator()
        host.setHasNoMainWindows(true)
        let initial = UUID()
        host.selectedIdValue = initial // initial workspace id captured before add
        host.workspaceCountValue = 2
        host.containsValue = true
        // After add, selected is the new browser workspace (so close gate passes).
        let created = UUID()
        host.createdWorkspaceId = created

        let result = coord.performNewBrowserWorkspaceAction(selector: "s", debugSource: "test")

        #expect(result == true)
        #expect(host.calls.contains("addWorkspace:browser"))
        #expect(host.focusedBrowserIds == [created])
    }

    @Test("Browser disabled beeps and returns false without creating")
    func browserDisabledBeeps() {
        let (coord, host) = makeCoordinator()
        host.browserEnabled = false

        let result = coord.performNewBrowserWorkspaceAction(selector: "s", debugSource: "test")

        #expect(result == false)
        #expect(host.beeps == 1)
        #expect(host.calls == ["beepBrowserDisabled"])
    }

    @Test("Remote tmux window short-circuits new workspace creation")
    func remoteTmuxShortCircuit() {
        let (coord, host) = makeCoordinator()
        host.setHasNoMainWindows(false)
        host.livePreferredWindow = WindowID(UUID())
        host.remoteHandled = true

        let result = coord.performNewWorkspaceAction(selector: "s", debugSource: "test")

        #expect(result == true)
        // No creation calls beyond resolution: configured action / group / preferred never reached.
        #expect(!host.calls.contains("executeConfiguredAction"))
        #expect(!host.calls.contains(where: { $0.hasPrefix("createWorkspaceInGroup") }))
    }

    @Test("Configured action override wins for terminal before group/preferred paths")
    func configuredActionOverride() {
        let (coord, host) = makeCoordinator()
        host.setHasNoMainWindows(false)
        host.livePreferredWindow = WindowID(UUID())
        host.configuredActionRuns = true

        let result = coord.performNewWorkspaceAction(selector: "s", debugSource: "test")

        #expect(result == true)
        #expect(host.calls.contains("executeConfiguredAction"))
        #expect(!host.calls.contains(where: { $0.hasPrefix("createWorkspaceInGroup") }))
    }

    @Test("Browser variant skips configured action and creates in group when grouped")
    func browserInGroup() {
        let (coord, host) = makeCoordinator()
        host.setHasNoMainWindows(false)
        host.livePreferredWindow = WindowID(UUID())
        host.membership = WorkspaceGroupMembership(
            selectedWorkspaceId: UUID(), groupId: UUID(), anchorCwd: "/repo"
        )
        host.configuredPlacement = .top
        let created = UUID()
        host.createdWorkspaceId = created

        let result = coord.performNewBrowserWorkspaceAction(selector: "s", debugSource: "test")

        #expect(result == true)
        #expect(!host.calls.contains("executeConfiguredAction"))
        #expect(host.calls.contains("createWorkspaceInGroup:top:browser"))
        #expect(host.focusedBrowserIds == [created])
    }

    @Test("Preferred-manager path used when present and either contextless or live")
    func preferredManagerPath() {
        let (coord, host) = makeCoordinator()
        host.setHasNoMainWindows(false)
        host.livePreferredWindow = nil
        host.preferredCreationWindow = WindowID(UUID())
        host.preferredManagerPresent = true
        host.preferredManagerHasNoContext = true

        let result = coord.performNewWorkspaceAction(selector: "s", debugSource: "test")

        #expect(result == true)
        #expect(host.calls.contains("addWorkspaceToPreferredTabManager:terminal"))
    }

    @Test("Preferred-window fallback opens a new window when creation returns nil")
    func preferredWindowNilFallback() {
        let (coord, host) = makeCoordinator()
        host.setHasNoMainWindows(false)
        host.livePreferredWindow = nil
        host.preferredCreationWindow = WindowID(UUID())
        host.preferredManagerPresent = false
        // addWorkspaceInPreferredMainWindow returns nil → new-window fallback.
        host.createdWorkspaceId = UUID()
        let fakeNil = FakeNilHost()
        let coord2 = WorkspaceCreationActionCoordinator(host: fakeNil)
        _ = coord2.performNewWorkspaceAction(selector: "s", debugSource: "test")
        #expect(fakeNil.openedNewWindows == 1)
        #expect(fakeNil.calls.contains("logFallbackNewWindow:workspace_creation_returned_nil"))
    }

    @Test("Cloud VM beeps when no window can be resolved")
    func cloudVMNoWindowBeeps() {
        let (coord, host) = makeCoordinator()
        host.cloudVMWindow = nil

        let result = coord.performCloudVMAction(selector: "s", debugSource: "test", onCompletion: nil)

        #expect(result == false)
        #expect(host.beeps == 1)
        #expect(!host.calls.contains("startCloudVM"))
    }

    @Test("Cloud VM starts the launcher when a window resolves")
    func cloudVMStarts() {
        let (coord, host) = makeCoordinator()
        host.cloudVMWindow = WindowID(UUID())
        host.cloudVMStarts = true

        let result = coord.performCloudVMAction(selector: "s", debugSource: "test", onCompletion: nil)

        #expect(result == true)
        #expect(host.calls.contains("startCloudVM"))
    }

    @Test("Group target resolves configured placement over the stored default")
    func groupTargetConfiguredPlacement() {
        let (coord, host) = makeCoordinator()
        let win = WindowID(UUID())
        let sel = UUID()
        let grp = UUID()
        host.membership = WorkspaceGroupMembership(selectedWorkspaceId: sel, groupId: grp, anchorCwd: "/x")
        host.configuredPlacement = .afterCurrent
        host.defaultPlacement = .end

        let target = coord.workspaceGroupNewWorkspaceTarget(in: win)

        #expect(target?.groupId == grp)
        #expect(target?.referenceWorkspaceId == sel)
        #expect(target?.placement == .afterCurrent)
    }

    @Test("Group target falls back to the stored default placement when unconfigured")
    func groupTargetDefaultPlacement() {
        let (coord, host) = makeCoordinator()
        host.membership = WorkspaceGroupMembership(selectedWorkspaceId: UUID(), groupId: UUID(), anchorCwd: nil)
        host.configuredPlacement = nil
        host.defaultPlacement = .top

        let target = coord.workspaceGroupNewWorkspaceTarget(in: WindowID(UUID()))

        #expect(target?.placement == .top)
    }

    @Test("Group target is nil when the selected workspace is not grouped")
    func groupTargetUngrouped() {
        let (coord, host) = makeCoordinator()
        host.membership = nil
        #expect(coord.workspaceGroupNewWorkspaceTarget(in: WindowID(UUID())) == nil)
    }

    @Test("closeInitialWorkspaceIfNeeded closes only when count>1, exists, and not selected")
    func closeInitialGate() {
        let (coord, host) = makeCoordinator()
        let win = WindowID(UUID())
        let initial = UUID()
        host.workspaceCountValue = 2
        host.containsValue = true
        host.selectedIdValue = UUID() // different from initial

        coord.closeInitialWorkspaceIfNeeded(initialWorkspaceId: initial, in: win)
        #expect(host.closedWorkspaceIds == [initial])
    }

    @Test("closeInitialWorkspaceIfNeeded is a no-op when only one workspace remains")
    func closeInitialSingleWorkspace() {
        let (coord, host) = makeCoordinator()
        host.workspaceCountValue = 1
        coord.closeInitialWorkspaceIfNeeded(initialWorkspaceId: UUID(), in: WindowID(UUID()))
        #expect(host.closedWorkspaceIds.isEmpty)
    }

    @Test("closeInitialWorkspaceIfNeeded is a no-op when the initial is the selected one")
    func closeInitialIsSelected() {
        let (coord, host) = makeCoordinator()
        let initial = UUID()
        host.workspaceCountValue = 3
        host.containsValue = true
        host.selectedIdValue = initial
        coord.closeInitialWorkspaceIfNeeded(initialWorkspaceId: initial, in: WindowID(UUID()))
        #expect(host.closedWorkspaceIds.isEmpty)
    }
}

/// Variant host that returns nil from the preferred-main-window add so the
/// new-window fallback branch can be exercised in isolation.
@MainActor
private final class FakeNilHost: WorkspaceCreationActionHosting {
    typealias SelectionContext = String
    private(set) var calls: [String] = []
    private(set) var openedNewWindows = 0

    func livePreferredWindowToken(for selector: SelectionContext) -> WindowID? { nil }
    var hasNoMainWindows: Bool { false }
    func preferredWindowTokenForCreation(selector: SelectionContext, debugSource: String) -> WindowID? { WindowID(UUID()) }
    func windowTokenForCloudVM(selector: SelectionContext, debugSource: String) -> WindowID? { nil }
    func createMainWindowToken() -> WindowID { WindowID(UUID()) }
    func openNewMainWindow() { openedNewWindows += 1 }
    func logFallbackNewWindow(selector: SelectionContext, source: String, reason: String) { calls.append("logFallbackNewWindow:\(reason)") }
    func selectedWorkspaceId(in windowToken: WindowID) -> UUID? { nil }
    func addWorkspace(in windowToken: WindowID, initialSurface: NewWorkspaceInitialSurface) -> UUID? { nil }
    func hasPreferredTabManager(selector: SelectionContext) -> Bool { false }
    func preferredTabManagerHasNoMainWindowContext(selector: SelectionContext) -> Bool { false }
    func addWorkspaceToPreferredTabManager(selector: SelectionContext, initialSurface: NewWorkspaceInitialSurface) -> UUID? { nil }
    func createWorkspaceInGroup(in windowToken: WindowID, target: WorkspaceGroupNewWorkspaceTarget, initialSurface: NewWorkspaceInitialSurface) -> UUID? { nil }
    func addWorkspaceInPreferredMainWindow(selector: SelectionContext, initialSurface: NewWorkspaceInitialSurface, debugSource: String) -> UUID? { nil }
    func focusInitialBrowserAddressBar(workspaceId: UUID) {}
    func workspaceCount(in windowToken: WindowID) -> Int { 1 }
    func containsWorkspace(_ workspaceId: UUID, in windowToken: WindowID) -> Bool { false }
    func closeWorkspace(_ workspaceId: UUID, in windowToken: WindowID) {}
    func handleRemoteWindowNewWorkspaceRequested(in windowToken: WindowID) -> Bool { false }
    var isBrowserEnabled: Bool { true }
    func beep() {}
    func beepBrowserDisabled(source: String) {}
    func selectedWorkspaceGroupMembership(in windowToken: WindowID) -> WorkspaceGroupMembership? { nil }
    func configuredWorkspaceGroupNewPlacement(in windowToken: WindowID, anchorCwd: String?) -> WorkspaceGroupNewPlacement? { nil }
    var defaultWorkspaceGroupNewPlacement: WorkspaceGroupNewPlacement { .end }
    func executeConfiguredNewWorkspaceActionIfAvailable(in windowToken: WindowID, debugSource: String, replacingInitialWorkspaceId: UUID?, target: WorkspaceGroupNewWorkspaceTarget?) -> Bool { false }
    func startCloudVM(in windowToken: WindowID, selector: SelectionContext, onCompletion: ((CloudVMActionCompletion) -> Void)?) -> Bool { false }
}
