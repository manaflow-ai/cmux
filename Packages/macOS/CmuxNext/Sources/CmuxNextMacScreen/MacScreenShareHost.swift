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
    /// Permission checks; tests replace them. Each is a synchronous TCC query (an IPC to tccd: Screen
    /// Recording waits on TCC's serial `com.apple.tcc.preflight.kTCCServiceScreenCapture` queue), so they
    /// run on the system lane, never on the main thread.
    @ObservationIgnored public var checkScreenRecording: @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }
    @ObservationIgnored public var checkAccessibility: @Sendable () -> Bool = { AXIsProcessTrusted() }
    @ObservationIgnored private let work: BackgroundWork
    /// The number of reads started; a read applies its answer only when no later read has started.
    @ObservationIgnored private var reads: UInt64 = 0

    /// - Parameter work: the app's blocking-work lanes; the permission checks run on its system lane.
    public init(work: BackgroundWork) {
        self.work = work
    }

    /// At launch: reads the permissions and rechecks them whenever the app becomes active, on the
    /// app's one activation observer (`events`; Chromium's app controller observes NSApp once,
    /// chrome/browser/app_controller_mac.mm). No node: a permission granted in System Settings
    /// counts whether or not a Mac Screen tab shows. Each read runs on the system lane (``refreshPermissions()``).
    public func activate(events: AppEvents) {
        // task-owner: one permission read; a later read supersedes its answer
        Task { await refreshPermissions() }
        guard activation == nil else { return }
        activation = events.subscribe(NSApplication.didBecomeActiveNotification, owner: "MacScreenShareHost.activation") { [weak self] in
            guard let self else { return }
            // task-owner: one permission read; a later read supersedes its answer
            Task { await self.refreshPermissions() }
        }
    }

    /// Reads both permissions off the main thread and shows them. When reads overlap, the last one
    /// started decides (an older answer that arrives later is dropped). A failed read (cancelled, or the
    /// app is quitting) changes nothing.
    public func refreshPermissions() async {
        reads &+= 1
        let read = reads
        let screenRecording = checkScreenRecording, accessibility = checkAccessibility
        // Shown on the Mac Screen page and in Settings soon: userVisible.
        guard let granted = try? await work.run(.userVisible, mayBlock: .system, { (screenRecording(), accessibility()) }),
              read == reads else { return }
        screenRecordingGranted = granted.0
        accessibilityGranted = granted.1
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
