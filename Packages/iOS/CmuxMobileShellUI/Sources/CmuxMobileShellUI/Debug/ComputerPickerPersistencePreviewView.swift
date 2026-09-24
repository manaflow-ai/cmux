#if os(iOS) && DEBUG
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// Exercises the production shell's picker and preferences with fixed Mac snapshots.
/// Selection is never seeded: relaunches read the same preferences as the real app.
public struct ComputerPickerPersistencePreviewView: View {
    @State private var store = CMUXMobileShellStore(
        isSignedIn: true,
        connectionState: .disconnected,
        workspaces: [
            MobileWorkspacePreview(
                id: "workspace-main",
                macDeviceID: "picker-mac",
                macDisplayName: "MacBook Pro",
                name: "cmux",
                terminals: []
            ),
            MobileWorkspacePreview(
                id: "workspace-other",
                macDeviceID: "picker-studio",
                macDisplayName: "Mac Studio",
                name: "Docs",
                terminals: []
            ),
        ]
    )
    private let browserStore = BrowserSurfaceStore()
    private let browserStreamStore = BrowserStreamStore()
    private let simulatorStreamStore = MobileSimulatorStreamStore()

    /// Creates an isolated source of computer snapshots without network discovery.
    public init() {}

    /// Renders the same picker, filtering, and preference owner as the app.
    public var body: some View {
        WorkspaceShellView(
            store: store,
            signOut: {},
            isInitialConnectionLoading: false,
            initialConnectionTimedOut: false,
            retryInitialConnection: nil,
            showAddDevice: nil,
            showPairingScanner: nil,
            showSettings: {},
            showComputers: {}
        )
        .environment(browserStore)
        .environment(browserStreamStore)
        .environment(simulatorStreamStore)
    }
}
#endif
