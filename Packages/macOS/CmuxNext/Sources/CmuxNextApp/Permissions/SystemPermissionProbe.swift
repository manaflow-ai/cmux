import AppKit
import AVFoundation
import CmuxNextAgentPermissions
import CmuxNextCompat
import CmuxNextOnboarding
import CmuxNextWakeups
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
    /// The app's fan-out of app notices (the app becoming active).
    private let appEvents: AppEvents
    /// Where the grants' observation flushes.
    private let mainWork: MainWorkScheduler

    /// - Parameters:
    ///   - setup: Computer Use Setup: the helper's grants, and the app's fan-out of distributed notices.
    ///   - appEvents: The app's fan-out of app notices.
    ///   - mainWork: The app's main-thread scheduler.
    init(setup: ComputerUseSetup, appEvents: AppEvents, mainWork: MainWorkScheduler) {
        self.setup = setup
        self.appEvents = appEvents
        self.mainWork = mainWork
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
        let subscriptions = [
            appEvents.subscribe(NSApplication.didBecomeActiveNotification, owner: "SystemPermissionProbe.active") {
                continuation.yield()
            },
            setup.distributedEvents.subscribe(ComputerUseSetup.accessibilityTrustChanged, owner: "SystemPermissionProbe.trust") {
                continuation.yield()
            },
        ]
        let setup = setup
        // A service observation while the stream lives: the request store re-reads on each element, shown or
        // not. `visible`: the permission card shows the grants.
        let grants = ServiceObservation(.visible, owner: "SystemPermissionProbe.grants", on: mainWork) {
            ObservationTrigger(setup.permissions)
        } apply: { _ in
            continuation.yield()
        }
        let mainWork = mainWork
        continuation.onTermination = { _ in
            // The stream's end, on any thread: the subscriptions and the observation stop in one background task.
            mainWork.postFromAnyThread(.background, owner: "SystemPermissionProbe.end") {
                for subscription in subscriptions { subscription.cancel() }
                grants.cancel()
            }
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
        // SAFETY: open reads the NUL-terminated copy of the path Swift makes for the call.
        let fd = unsafe open(path, O_RDONLY)
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
