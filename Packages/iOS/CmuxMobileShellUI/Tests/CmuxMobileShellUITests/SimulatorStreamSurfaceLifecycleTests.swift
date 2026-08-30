#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileWorkspace
import SwiftUI
import Testing
@preconcurrency import UIKit
@testable import CmuxMobileShellUI

@MainActor
@Suite struct SimulatorStreamSurfaceLifecycleTests {
    /// Connection recovery can transiently unmount the selected pane. View
    /// visibility is not selection intent, so removing the view hierarchy must
    /// leave the store selection available for composite-owned wire recovery.
    @Test func transientUnmountKeepsSelectedSimulatorActive() async throws {
        let lifecycle = SimulatorStreamTestLifecycle()
        var lifecycleEvents = lifecycle.events.makeAsyncIterator()
        let workspaceID = "workspace-1"
        let descriptor = simulatorDescriptor(workspaceID: workspaceID)
        let simulatorStore = MobileSimulatorStreamStore()
        simulatorStore.replaceSimulatorPanels(in: workspaceID, with: [descriptor])
        simulatorStore.activate(panelID: descriptor.panelID, in: workspaceID)
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: workspaceID),
            name: "Workspace",
            terminals: [],
            simulators: [descriptor]
        )
        let shell = MobileShellComposite(
            workspaces: [workspace],
            simulatorStreamStore: simulatorStore
        )
        let detail = WorkspaceDetailView(
            connectionStatus: .connected,
            workspace: workspace,
            store: shell,
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
        let simulator = try #require(simulatorStore.activeState(in: workspaceID))
        let root = SimulatorStreamSurfaceLifecycleHarness(
            content: detail.simulatorStreamContent(simulator),
            lifecycle: lifecycle
        )
        let controller = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))

        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let appeared = await lifecycleEvents.next()
        #expect(appeared == .appeared)
        #expect(simulatorStore.activeState(in: workspaceID)?.id == descriptor.panelID)

        window.rootViewController = UIViewController()
        let disappeared = await lifecycleEvents.next()
        #expect(disappeared == .disappeared)

        #expect(simulatorStore.activeState(in: workspaceID)?.id == descriptor.panelID)
        window.isHidden = true
    }

    /// The route owner, not a child pane callback, distinguishes a transient
    /// remount from navigation away or to another workspace.
    @Test func visibleWorkspaceRouteFollowsNavigationState() {
        let workspaceA = MobileWorkspacePreview.ID(rawValue: "workspace-a")
        let workspaceB = MobileWorkspacePreview.ID(rawValue: "workspace-b")

        #expect(WorkspaceShellView.visibleSimulatorStreamWorkspaceID(
            selectedPrimaryTab: .workspaces,
            searchScope: .workspaces,
            usesCompactStack: true,
            selectedWorkspaceID: workspaceA,
            compactNavigationPath: [workspaceA],
            notificationNavigationPath: [],
            workspaceSearchNavigationPath: [],
            notificationSearchNavigationPath: []
        ) == workspaceA)
        #expect(WorkspaceShellView.visibleSimulatorStreamWorkspaceID(
            selectedPrimaryTab: .workspaces,
            searchScope: .workspaces,
            usesCompactStack: true,
            selectedWorkspaceID: workspaceA,
            compactNavigationPath: [],
            notificationNavigationPath: [],
            workspaceSearchNavigationPath: [],
            notificationSearchNavigationPath: []
        ) == nil)
        #expect(WorkspaceShellView.visibleSimulatorStreamWorkspaceID(
            selectedPrimaryTab: .workspaces,
            searchScope: .workspaces,
            usesCompactStack: false,
            selectedWorkspaceID: workspaceB,
            compactNavigationPath: [],
            notificationNavigationPath: [],
            workspaceSearchNavigationPath: [],
            notificationSearchNavigationPath: []
        ) == workspaceB)
        #expect(WorkspaceShellView.visibleSimulatorStreamWorkspaceID(
            selectedPrimaryTab: .notifications,
            searchScope: .workspaces,
            usesCompactStack: true,
            selectedWorkspaceID: workspaceA,
            compactNavigationPath: [workspaceA],
            notificationNavigationPath: [workspaceB],
            workspaceSearchNavigationPath: [],
            notificationSearchNavigationPath: []
        ) == workspaceB)
        #expect(WorkspaceShellView.visibleSimulatorStreamWorkspaceID(
            selectedPrimaryTab: .search,
            searchScope: .workspaces,
            usesCompactStack: true,
            selectedWorkspaceID: workspaceB,
            compactNavigationPath: [],
            notificationNavigationPath: [],
            workspaceSearchNavigationPath: [workspaceA],
            notificationSearchNavigationPath: [workspaceB]
        ) == workspaceA)
    }

    private func simulatorDescriptor(workspaceID: String) -> MobileSimulatorPanelDescriptor {
        MobileSimulatorPanelDescriptor(
            panelID: "sim-1",
            workspaceID: workspaceID,
            title: "Simulator",
            selectedDeviceName: "iPhone 17",
            selectedDeviceState: "Booted",
            status: "streaming",
            isReady: true,
            supportsTouch: true,
            supportsKeyboard: true,
            supportsHardwareButtons: true,
            supportsRotation: true,
            ownerConnectionID: "phone",
            isOwnedByCurrentConnection: true
        )
    }
}

private struct SimulatorStreamSurfaceLifecycleHarness<Content: View>: View {
    let content: Content
    let lifecycle: SimulatorStreamTestLifecycle

    var body: some View {
        content
            .onAppear { lifecycle.record(.appeared) }
            .onDisappear { lifecycle.record(.disappeared) }
    }
}

@MainActor
private final class SimulatorStreamTestLifecycle {
    enum Event: Equatable {
        case appeared
        case disappeared
    }

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    func record(_ event: Event) {
        continuation.yield(event)
    }
}
#endif
