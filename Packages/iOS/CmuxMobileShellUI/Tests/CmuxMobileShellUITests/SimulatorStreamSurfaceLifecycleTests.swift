#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileToast
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
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let root = WorkspaceDetailView(
            host: "Mac",
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
        .environment(BrowserSurfaceStore())
        .environment(BrowserStreamStore())
        .environment(simulatorStore)
        .environment(MobileDisplaySettings(defaults: defaults, environment: [:]))
        .environment(ToastCenter(defaults: defaults))
        let controller = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))

        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        await Task.yield()
        #expect(simulatorStore.activeState(in: workspaceID)?.id == descriptor.panelID)

        window.rootViewController = UIViewController()
        await Task.yield()

        #expect(simulatorStore.activeState(in: workspaceID)?.id == descriptor.panelID)
        window.isHidden = true
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
#endif
