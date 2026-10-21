import AppKit
import AVFoundation
import CmuxNextAgentPermissions
import CmuxNextCompat
import CmuxNextOnboarding
import CoreServices
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
            return await Self.fullDiskAccess()
        case .camera:
            return Self.capture(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return Self.capture(AVCaptureDevice.authorizationStatus(for: .audio))
        case .automation:
            guard let target else { return .unknown }
            return await Self.automation(of: target, ask: false)
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

    private static func capture(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    /// Opens the user's TCC database for reading: only a process with Full
    /// Disk Access may. A missing file says nothing.
    @concurrent nonisolated static func fullDiskAccess() async -> PermissionStatus {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.TCC/TCC.db").path
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .granted
        }
        return errno == EPERM || errno == EACCES ? .denied : .unknown
    }

    /// Automation of `bundleID`; with `ask` macOS shows its one prompt (only after Continue).
    @concurrent nonisolated static func automation(of bundleID: String, ask: Bool) async -> PermissionStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        switch Int(status) {
        case Int(noErr): return .granted
        case -1743: return .denied // errAEEventNotPermitted
        case -1744: return .notDetermined // errAEEventWouldRequireUserConsent
        default: return .unknown // procNotFound: the app is not running
        }
    }
}
