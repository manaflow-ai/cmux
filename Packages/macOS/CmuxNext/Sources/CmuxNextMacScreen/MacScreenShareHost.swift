public import AppKit
import ApplicationServices
public import CmuxNextWakeups
import CmuxNextCompat
import CoreGraphics
public import Observation
import SystemConfiguration

/// The permissions this Mac needs to share its screen through the device
/// hub ("Allow Mac Screen on this Mac", `MacScreenHubHost`): Screen
/// Recording (the picture) and Accessibility (the input), rechecked when
/// the app becomes active (after System Settings). Link-mode sharing (a
/// pairing link anyone could use) is gone.
@Observable
public final class MacScreenShareHost {
    public private(set) var screenRecordingGranted = false
    public private(set) var accessibilityGranted = false
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    /// A fresh child reads TCC under this app's responsibility, just like `rd serve`. A long-running
    /// process can cache Screen Recording denial even after the person grants it in Settings.
    @ObservationIgnored var readPermissions: @Sendable () async throws -> (screen: Bool, control: Bool) = {
        try await MacScreenPermissionProbe().read()
    }
    /// The number of reads started; a read applies its answer only when no later read has started.
    @ObservationIgnored private var reads: UInt64 = 0

    public init() {}

    /// At launch: reads the permissions and rechecks them whenever the app becomes active.
    public func activate() {
        Task { await refreshPermissions() }
        guard activation == nil else { return }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                guard let self else { return }
                Task { await self.refreshPermissions() }
            }
        }
    }

    /// Reads both permissions off the main thread and shows them. When reads overlap, the last one
    /// started decides (an older answer that arrives later is dropped). Cancellation changes nothing;
    /// an unavailable or failed probe clears permission state rather than keeping an old grant.
    public func refreshPermissions() async {
        reads &+= 1
        let read = reads
        let granted = try? await readPermissions()
        guard read == reads, !Task.isCancelled else { return }
        screenRecordingGranted = granted?.screen ?? false
        accessibilityGranted = granted?.control ?? false
    }

    public func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { openSettings(screenRecording: true) }
    }

    public func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openSettings(screenRecording: false) }
    }

    public func openSettings(screenRecording: Bool) {
        let pane = screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.openInBackground(url) }
    }

    /// The Mac's name from Sharing settings (fast; no DNS).
    public static var computerName: String {
        MacName.captureOverride ?? (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }
}
