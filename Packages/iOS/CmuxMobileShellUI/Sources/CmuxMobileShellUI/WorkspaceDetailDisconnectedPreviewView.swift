import CMUXMobileCore
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI

#if os(iOS) && DEBUG
/// DEBUG-only fixture for the terminal-opened-while-disconnected layout.
///
/// Mounted by the root view when `CMUX_UITEST_WORKSPACE_DETAIL_DISCONNECTED=1`.
/// The store is signed in and the shell opens directly onto a workspace with
/// one retained terminal whose Mac is unreachable
/// (`macConnectionStatus == .unavailable`, the "Disconnected" pill) — the exact
/// state where the composer dock seats with the keyboard down and input
/// blocked. Used to screenshot and regression-test the dock's keyboard-down
/// seat without a paired Mac.
///
/// `CMUX_UITEST_WORKSPACE_DETAIL_DISCONNECTED_SCENARIO` selects the timeline:
/// - `cold` (default): the terminal is disconnected from launch, no keyboard
///   ever appears.
/// - `drop-after-focus`: the terminal starts CONNECTED, the composer focuses
///   at t+2s (real keyboard), and the Mac drops to unavailable at t+9s — the
///   "Mac slept while I was typing" flow, where the blocked-input resign
///   dismisses the keyboard with no later keyboard event to re-seat the dock.
struct WorkspaceDetailDisconnectedPreviewView: View {
    private static let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-disconnected")
    private static let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-disconnected")

    private static var scenario: String {
        ProcessInfo.processInfo.environment[
            "CMUX_UITEST_WORKSPACE_DETAIL_DISCONNECTED_SCENARIO"
        ] ?? "cold"
    }

    private static var startsConnected: Bool {
        scenario == "drop-after-focus"
    }

    @State private var store = MobileShellComposite(
        isSignedIn: true,
        connectionState: startsConnected ? .connected : .disconnected,
        connectedHostName: "UI Test Mac",
        workspaces: initialWorkspaces
    )
    @State private var browserStore = BrowserSurfaceStore()
    @State private var browserStreamStore = BrowserStreamStore()
    @State private var simulatorStreamStore = MobileSimulatorStreamStore()
    @State private var didStartFixture = false

    var body: some View {
        WorkspaceShellView(
            store: store,
            signOut: {},
            showAddDevice: nil
        )
        .environment(browserStore)
        .environment(browserStreamStore)
        .environment(simulatorStreamStore)
        // The one-time What's New notice would cover the layout under test;
        // clearing the center suppresses it for this fixture only.
        .environment(nil as MobileWhatsNewCenter?)
        .task {
            guard !didStartFixture else { return }
            didStartFixture = true
            store.selectedWorkspaceID = Self.workspaceID
            store.selectedTerminalID = Self.terminalID
            guard Self.startsConnected else { return }
            // Real keyboard up over the connected terminal, like a user
            // mid-thought in the composer.
            try? await ContinuousClock().sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            store.presentAndFocusComposer(forTerminalID: Self.terminalID.rawValue)
            // The Mac drops while the keyboard is up (caffeinate expired /
            // Mac slept). The unavailable status blocks input, which resigns
            // the keyboard; nothing after this raises it again.
            try? await ContinuousClock().sleep(for: .seconds(7))
            guard !Task.isCancelled else { return }
            store.simulateForegroundMacUnavailableForPreview()
        }
    }

    private static func workspace(status: MobileMacConnectionStatus?) -> MobileWorkspacePreview {
        var workspace = MobileWorkspacePreview(
            id: workspaceID,
            name: "caffeinate -d -t 30000",
            terminals: [
                MobileTerminalPreview(id: terminalID, name: "caffeinate -d -t 30000"),
            ]
        )
        // The cold scenario stamps the retained row directly, exactly like a
        // stored workspace whose Mac just failed to reconnect. The connected
        // scenario leaves the row unstamped so the detail falls back to the
        // store's live status (connected, then unavailable after the drop).
        workspace.macConnectionStatus = status
        return workspace
    }

    private static var initialWorkspaces: [MobileWorkspacePreview] {
        [workspace(status: startsConnected ? nil : .unavailable)]
    }
}
#endif
