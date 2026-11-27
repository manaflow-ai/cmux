import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileWorkspace

/// The root scene must mount ONE workspace-shell surface across the startup
/// reconnect window resolving (connected, failed, or gate expired). Mounting a
/// different view per state destroyed the shell's presentation state: a
/// Settings sheet opened while "reconnecting to your Mac" dismissed itself the
/// moment the reconnection finished.
///
/// `showDisconnectedNoPairedMacShell` is the shell presentation policy's
/// resolved decision (no saved Macs AND no hidden computers), so these tests
/// pass it directly.
@Suite struct MobileRootShellSurfaceTests {
    @Test func restoringWindowIsWorkspaceShellData() {
        #expect(MobileRootAuthGate.shellSurface(
            connectionState: .disconnected,
            showRestoringStoredMac: true,
            showDisconnectedNoPairedMacShell: false
        ) == .workspaceShell(isRestoringStoredMac: true))
    }

    /// The regression: reconnect finishing must land on the SAME surface case
    /// as the restoring window, so the mounted shell view keeps its identity
    /// (and its open Settings sheet) across the transition.
    @Test func reconnectFinishingStaysOnWorkspaceShellSurface() {
        let restoring = MobileRootAuthGate.shellSurface(
            connectionState: .disconnected,
            showRestoringStoredMac: true,
            showDisconnectedNoPairedMacShell: false
        )
        let connected = MobileRootAuthGate.shellSurface(
            connectionState: .connected,
            showRestoringStoredMac: false,
            showDisconnectedNoPairedMacShell: false
        )
        #expect(isWorkspaceShell(restoring))
        #expect(isWorkspaceShell(connected))
        #expect(connected == .workspaceShell(isRestoringStoredMac: false))
    }

    /// A failed or gate-expired reconnect with saved Macs falls to the offline
    /// workspace shell, still the same surface case as the restoring window.
    @Test func failedReconnectWithSavedMacsStaysOnWorkspaceShellSurface() {
        #expect(MobileRootAuthGate.shellSurface(
            connectionState: .disconnected,
            showRestoringStoredMac: false,
            showDisconnectedNoPairedMacShell: false
        ) == .workspaceShell(isRestoringStoredMac: false))
    }

    /// A connected shell is never marked restoring, even if the caller's
    /// restoring signal is momentarily stale.
    @Test func connectedNeverReportsRestoring() {
        #expect(MobileRootAuthGate.shellSurface(
            connectionState: .connected,
            showRestoringStoredMac: true,
            showDisconnectedNoPairedMacShell: false
        ) == .workspaceShell(isRestoringStoredMac: false))
    }

    /// Never-paired devices (presentation policy resolved to the no-devices
    /// screen, no active restoring window) get the disconnected surface.
    @Test func neverPairedFallsToDisconnectedSurface() {
        #expect(MobileRootAuthGate.shellSurface(
            connectionState: .disconnected,
            showRestoringStoredMac: false,
            showDisconnectedNoPairedMacShell: true
        ) == .disconnectedNoKnownPairedMac)
    }

    /// While the paired-Mac hint is undetermined the restoring window can be
    /// active with no known Mac; restoring wins over the no-devices surface
    /// (matches the pre-existing branch priority).
    @Test func restoringWinsOverNeverPaired() {
        #expect(MobileRootAuthGate.shellSurface(
            connectionState: .disconnected,
            showRestoringStoredMac: true,
            showDisconnectedNoPairedMacShell: true
        ) == .workspaceShell(isRestoringStoredMac: true))
    }

    /// Connected always mounts the workspace shell, even if a stale
    /// presentation decision still says disconnected.
    @Test func connectedAlwaysMountsWorkspaceShell() {
        #expect(MobileRootAuthGate.shellSurface(
            connectionState: .connected,
            showRestoringStoredMac: false,
            showDisconnectedNoPairedMacShell: true
        ) == .workspaceShell(isRestoringStoredMac: false))
    }

    private func isWorkspaceShell(_ surface: MobileRootAuthGate.MobileRootShellSurface) -> Bool {
        if case .workspaceShell = surface { return true }
        return false
    }
}
