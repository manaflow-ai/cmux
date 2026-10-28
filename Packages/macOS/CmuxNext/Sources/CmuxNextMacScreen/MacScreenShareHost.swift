public import AppKit
import ApplicationServices
import CmuxNextCompatAppKit
public import CmuxNextWakeups
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
    @ObservationIgnored private var activation: EventSubscription?
    /// Permission checks; tests replace them.
    @ObservationIgnored public var checkScreenRecording: () -> Bool = { CGPreflightScreenCaptureAccess() }
    @ObservationIgnored public var checkAccessibility: () -> Bool = { AXIsProcessTrusted() }

    public init() {}

    /// At launch: reads the permissions and rechecks them whenever the app becomes active, on the
    /// app's one activation observer (`events`; Chromium's app controller observes NSApp once,
    /// chrome/browser/app_controller_mac.mm). No node: a permission granted in System Settings
    /// counts whether or not a Mac Screen tab shows.
    public func activate(events: AppEvents) {
        refreshPermissions()
        guard activation == nil else { return }
        activation = events.subscribe(NSApplication.didBecomeActiveNotification, owner: "MacScreenShareHost.activation") { [weak self] in
            self?.refreshPermissions()
        }
    }

    public func refreshPermissions() {
        screenRecordingGranted = checkScreenRecording()
        accessibilityGranted = checkAccessibility()
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
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }
}
