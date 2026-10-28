import AppKit
import AVFoundation
import CmuxNextAgentPermissions
import CmuxNextCompat

/// Takes the person to a grant after they pressed Continue on the card:
/// the System Settings list for kinds with a list, macOS's one prompt for
/// camera, microphone and automation. Computer use kinds first turn
/// Computer Use on when it is off, so the helper that needs the grant runs.
/// The helper's two grants open through Computer Use Setup, the same path as
/// Allow in Settings and onboarding: for Screen Recording it first asks the
/// running helper (`ComputerUseSetup.open`), without which macOS 26 keeps
/// the helper's capture check false and the card never ends `granted`.
@MainActor
final class SystemPermissionOpener: PermissionSettingsOpening {
    private let setup: ComputerUseSetup

    init(setup: ComputerUseSetup) {
        self.setup = setup
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
        case .accessibility, .computerUse:
            setup.open(.accessibility)
        case .screenRecording:
            setup.open(.screenRecording)
        case .fullDiskAccess:
            guard let url = kind.settingsURL else { return }
            NSWorkspace.shared.openInBackground(url)
        }
    }
}
