import CMUXMobileCore
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileShell
#if DEBUG
import CmuxMobileShellDebugSupport
#endif
import CmuxMobileShellModel
import SwiftUI

#if os(iOS) && DEBUG
/// Deterministic real-workspace fixture for Simulator chrome and stream-state verification.
public struct SimulatorDiscoverabilityPreviewView: View {
    @State private var store: MobileShellComposite
    @State private var browserStore = BrowserSurfaceStore()
    @State private var browserStreamStore = BrowserStreamStore()

    /// Creates a fixture with zero, one, two, or unsupported Simulator panels.
    public init(mode: String, state: String) {
        let workspaceID = "simulator-discoverability-workspace"
        let descriptors = Self.descriptors(mode: mode, state: state, workspaceID: workspaceID)
        let streamStore = MobileSimulatorStreamStore()
        streamStore.replaceSimulatorPanels(in: workspaceID, with: descriptors)
        streamStore.setSimulatorStreamConnectionStatus(
            state == "disconnected" ? .disconnected : .connected
        )

        if state != "inactive", let first = descriptors.first {
            _ = streamStore.activate(panelID: first.panelID, in: workspaceID)
            if state == "locked" {
                streamStore.state(for: first.panelID)?.markLockedByOtherConnection()
            } else if state == "stalled" {
                streamStore.state(for: first.panelID)?.markStreamStale()
            }
        }

        let terminalID = MobileTerminalPreview.ID(rawValue: "simulator-fixture-terminal")
        let workspace = MobileWorkspacePreview(
            id: MobileWorkspacePreview.ID(rawValue: workspaceID),
            name: "Simulator Fixture",
            terminals: [MobileTerminalPreview(id: terminalID, name: "Terminal")],
            simulators: descriptors
        )
        let shellStore = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            connectedHostName: "UI Test Mac",
            workspaces: [workspace],
            simulatorStreamStore: streamStore
        )
        if mode != "unsupported" {
            shellStore.enableSimulatorStreamPreviewCapability()
        }
        shellStore.selectedWorkspaceID = workspace.id
        shellStore.selectedTerminalID = terminalID

        _store = State(initialValue: shellStore)
    }

    public var body: some View {
        WorkspaceShellView(store: store, signOut: {}, showAddDevice: nil)
            .environment(browserStore)
            .environment(browserStreamStore)
            .environment(store.simulatorStreamStore)
    }

    private static func descriptors(
        mode: String,
        state: String,
        workspaceID: String
    ) -> [MobileSimulatorPanelDescriptor] {
        let count: Int
        switch mode {
        case "one": count = 1
        case "two": count = 2
        case "unsupported": count = 1
        default: count = 0
        }
        return (0..<count).map { index in
            let suffix = index == 0 ? "A" : "B"
            return MobileSimulatorPanelDescriptor(
                panelID: "sim-\(suffix.lowercased())",
                workspaceID: workspaceID,
                title: "Simulator \(suffix)",
                selectedDeviceName: "iPhone \(suffix)",
                selectedDeviceState: "Booted",
                status: "streaming",
                isReady: true,
                supportsTouch: true,
                supportsKeyboard: true,
                supportsHardwareButtons: true,
                supportsRotation: true,
                ownerConnectionID: state == "locked" ? "other-phone" : nil,
                isOwnedByCurrentConnection: state == "locked" ? false : nil
            )
        }
    }
}
#endif
