import AppKit
public import AVFoundation
import CoreServices
import Foundation

/// The shared platform calls used by the existing permission probe and opener.
public nonisolated struct SystemPermissionAccess: Sendable {
    public init() {}
    public func capture(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    /// Opens the user's TCC database for reading: only a process with Full
    /// Disk Access may. A missing file says nothing.
    @concurrent nonisolated public func fullDiskAccess() async -> PermissionStatus {
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
    @concurrent nonisolated public func automation(of bundleID: String, ask: Bool) async -> PermissionStatus {
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
