import AppKit
import AVFoundation
import CmuxNextAgentPermissions
import CmuxNextCompatAppKit
import CmuxNextWakeups

/// Takes the person to a grant after they pressed Continue on the card:
/// the System Settings list for kinds with a list, macOS's one prompt for
/// camera, microphone and automation. Computer use kinds first turn
/// Computer Use on when it is off, so the helper that needs the grant runs.
@MainActor
final class SystemPermissionOpener: PermissionSettingsOpening {
    private let setup: ComputerUseSetup
    /// Starts the prompts off main: the person pressed Continue and waits for them.
    private let work: BackgroundWork

    init(setup: ComputerUseSetup, work: BackgroundWork) {
        self.setup = setup
        self.work = work
    }

    func open(_ kind: PermissionKind, target: String?) {
        if kind.heldByComputerUseHelper, setup.phase == .off { setup.enable() }
        switch kind {
        case .camera, .microphone:
            let camera = kind == .camera
            // task-owner: one macOS prompt; the probe's next read sees the answer.
            work.task(.userBlocking) { _ = await AVCaptureDevice.requestAccess(for: camera ? .video : .audio) }
        case .automation:
            guard let target else { return }
            // task-owner: one macOS prompt, off the main actor (the call blocks until the person answers).
            work.task(.userBlocking) { _ = await SystemPermissionProbe.automation(of: target, ask: true) }
        case .fullDiskAccess, .accessibility, .screenRecording, .computerUse:
            guard let url = kind.settingsURL else { return }
            NSWorkspace.shared.openInBackground(url)
        }
    }
}
