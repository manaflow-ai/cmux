import AppKit
import AVFoundation
import CmuxNextAgentPermissions
import CmuxNextCompat
import CmuxNextSettings

/// Takes the person to a grant after they pressed Continue on the card:
/// the Computer Use window for the grants the helper holds, the System
/// Settings list for Full Disk Access, macOS's one prompt for camera,
/// microphone and automation. Computer use kinds first turn Computer Use
/// on when it is off, so the helper that needs the grant runs.
@MainActor
final class SystemPermissionOpener: PermissionSettingsOpening {
    private let setup: ComputerUseSetup
    /// Opens (or brings forward) the Computer Use window.
    private let showComputerUse: @MainActor () -> Void
    private let openURL: @MainActor (URL) -> Void

    init(setup: ComputerUseSetup, showComputerUse: @escaping @MainActor () -> Void,
         openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.openInBackground($0) }) {
        self.setup = setup
        self.showComputerUse = showComputerUse
        self.openURL = openURL
    }

    /// Whether Continue on `kind` hands the person to the Computer Use window
    /// (the legacy helper's grants). Under `.upstream` the card itself guides
    /// the grant, so it must stay up; the presenter reads this same rule.
    nonisolated static func guidesInWindow(_ kind: PermissionKind, driver: ComputerUseDriver) -> Bool {
        kind.heldByComputerUseHelper && driver != .upstream
    }

    func open(_ kind: PermissionKind, target: String?) {
        if kind.heldByComputerUseHelper, setup.phase == .off { setup.enable() }
        switch kind {
        case .camera, .microphone:
            // task-owner: one macOS prompt; the probe's next read sees the answer.
            Task { _ = await AVCaptureDevice.requestAccess(for: kind == .camera ? .video : .audio) }
        case .automation:
            guard let target else { return }
            // task-owner: one macOS prompt, off the main actor (the call blocks until the person answers).
            Task { _ = await SystemPermissionProbe.automation(of: target, ask: true) }
        // The window guides both helper grants in order, with the drag panel docked to System Settings.
        // It reads the legacy helper's grants: under the helper v2 the card asks for its grant directly.
        case .accessibility, .screenRecording, .computerUse:
            guard !Self.guidesInWindow(kind, driver: setup.driver) else { return showComputerUse() }
            setup.open(kind == .screenRecording ? .screenRecording : .accessibility)
        case .fullDiskAccess:
            guard let url = kind.settingsURL else { return }
            openURL(url)
        }
    }
}
