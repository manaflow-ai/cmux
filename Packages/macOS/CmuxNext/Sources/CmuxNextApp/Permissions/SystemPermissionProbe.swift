import AppKit
import AVFoundation
import CmuxNextAgentPermissions
import CmuxNextCompat
import CmuxNextOnboarding
import Foundation

/// The App's TCC reads for agent permission requests. It never prompts:
/// the helper's grants come from Computer Use Setup (`permissions_status`
/// in the helper), Full Disk Access from opening the TCC database for
/// reading, camera and microphone from `AVCaptureDevice`, automation from
/// `AEDeterminePermissionToAutomateTarget` without asking.
///
/// Changes: the app becoming active (the person comes back from System
/// Settings), macOS's Accessibility trust notification, and each change of
/// Computer Use Setup's grants. Nothing polls.
@MainActor
final class SystemPermissionProbe: PermissionProbe {
    private let setup: ComputerUseSetup
    private let notifications: NotificationCenter
    private let distributed: NotificationCenter

    init(setup: ComputerUseSetup, notifications: NotificationCenter = .default,
         distributed: NotificationCenter = DistributedNotificationCenter.default()) {
        self.setup = setup
        self.notifications = notifications
        self.distributed = distributed
    }

    func status(_ kind: PermissionKind, target: String?) async -> PermissionStatus {
        switch kind {
        case .accessibility, .screenRecording, .computerUse:
            guard setup.phase == .ready else { return .unknown }
            let held = setup.permissions
            let granted = kind.grants.allSatisfy { $0 == .accessibility ? held.accessibility : held.screenRecording }
            return granted ? .granted : .denied
        case .fullDiskAccess:
            return await SystemPermissionAccess().fullDiskAccess()
        case .camera:
            return SystemPermissionAccess().capture(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return SystemPermissionAccess().capture(AVCaptureDevice.authorizationStatus(for: .audio))
        case .automation:
            guard let target else { return .unknown }
            return await SystemPermissionAccess().automation(of: target, ask: false)
        }
    }

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let active = notifications.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            continuation.yield()
        }
        let trust = distributed.addObserver(forName: ComputerUseSetup.accessibilityTrustChanged, object: nil, queue: .main) { _ in
            continuation.yield()
        }
        let setup = setup
        // task-owner: follows Computer Use Setup's grants while the stream lives; onTermination cancels it.
        let grants = Task { @MainActor in
            for await _ in ObservationStream({ ObservationTrigger(setup.permissions) }) { continuation.yield() }
        }
        nonisolated(unsafe) let observers: [any NSObjectProtocol] = [active, trust] // crash-allow: an immutable array of opaque observer tokens, read only by onTermination (runs once); removeObserver is thread-safe
        let notifications = notifications
        let distributed = distributed
        continuation.onTermination = { _ in
            grants.cancel()
            notifications.removeObserver(observers[0])
            distributed.removeObserver(observers[1])
        }
        return stream
    }

}
