#if os(iOS) && DEBUG
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import SwiftUI

/// Exercises the production shell's picker and preferences with fixed Mac snapshots.
/// Selection is never seeded: relaunches read the same preferences as the real app.
public struct ComputerPickerPersistencePreviewView: View {
    @State private var store = CMUXMobileShellStore(
        isSignedIn: true,
        connectionState: .disconnected,
        workspaces: initialWorkspaces
    )

    private static var initialWorkspaces: [MobileWorkspacePreview] {
        if refreshesPicker { return refreshingWorkspaces(generation: 0) }
        return [
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
    }
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
        .task {
            guard Self.refreshesPicker else { return }
            var generation = 0
            while !Task.isCancelled {
                try? await ContinuousClock().sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                generation += 1
                store.replaceForegroundWorkspaceState(Self.refreshingWorkspaces(generation: generation))
            }
        }
    }

    private static var refreshesPicker: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_COMPUTER_PICKER_REFRESH"] == "1"
    }

    private static func refreshingWorkspaces(generation: Int) -> [MobileWorkspacePreview] {
        (0...24).map { index in
            MobileWorkspacePreview(
                id: .init(rawValue: "picker-workspace-\(index)"),
                macDeviceID: "picker-refresh-\(index)",
                macDisplayName: String(format: "Computer %02d refresh %d", index, generation),
                name: "Workspace \(index)",
                terminals: []
            )
        }
    }
}
#endif
