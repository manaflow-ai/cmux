public import AppKit
import ApplicationServices
public import CmuxNextWakeups
import CmuxNextCompat
import CoreGraphics
public import Observation
import SystemConfiguration

/// The permissions this Mac needs to share its screen through the device
/// hub ("Allow Mac Screen on this Mac", `MacScreenHubHost`): Screen
/// Recording (the picture) and Accessibility (the input). They belong to the
/// Screen Sharing helper (``MacScreenHelper``, plans/cmux-next/screen-sharing-helper.md),
/// which serves every session: the reads and the requests run in a fresh helper
/// process, so macOS prompts for, lists and restarts the helper, and a grant
/// never relaunches this app. A build without the helper reads and requests
/// them for this app, as before. Rechecked when the app becomes active (after
/// System Settings). Link-mode
/// sharing (a pairing link anyone could use) is gone.
@Observable
public final class MacScreenShareHost {
    public private(set) var screenRecordingGranted = false
    public private(set) var accessibilityGranted = false
    /// The name System Settings lists the two grants under: the helper's
    /// ("cmux NIGHTLY Screen Sharing"), or nil while unknown and in a build
    /// without the helper (then they are this app's own).
    public private(set) var grantHolderName: String?
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    /// Permission checks of a build without the helper; tests replace them. Each is a synchronous
    /// TCC query (an IPC to tccd: Screen Recording waits on TCC's serial
    /// `com.apple.tcc.preflight.kTCCServiceScreenCapture` queue), so they run on the system lane,
    /// never on the main thread.
    @ObservationIgnored public var checkScreenRecording: @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }
    @ObservationIgnored public var checkAccessibility: @Sendable () -> Bool = { AXIsProcessTrusted() }
    /// This build's Screen Sharing helper (a disk lookup, run on the system lane); tests replace it.
    @ObservationIgnored var helper: @Sendable () -> MacScreenHelper? = { MacScreenHelper.bundled() }
    /// The helper once looked up (`.some(nil)`: this build has none); a build never gains or loses it.
    @ObservationIgnored private var lookedUp: MacScreenHelper??
    @ObservationIgnored private let work: BackgroundWork
    /// The number of reads started; a read applies its answer only when no later read has started.
    @ObservationIgnored private var reads: UInt64 = 0

    /// What the system lane found: the helper to ask, or this app's own grants (no helper).
    private enum LocalRead: Sendable {
        case helper(MacScreenHelper)
        case granted(Bool, Bool)
    }

    /// - Parameter work: the app's blocking-work lanes; the permission checks run on its system lane.
    public init(work: BackgroundWork) {
        self.work = work
    }

    /// At launch: reads the permissions and rechecks them whenever the app becomes active (back
    /// from System Settings, where the switches are).
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

    /// Reads both permissions off the main thread and shows them: the helper's, from a fresh
    /// helper process, or this app's in a build without the helper. When reads overlap, the last
    /// one started decides (an older answer that arrives later is dropped). A failed read
    /// (cancelled, the helper did not answer, or the app is quitting) changes nothing.
    public func refreshPermissions() async {
        reads &+= 1
        let read = reads
        let screenRecording = checkScreenRecording, accessibility = checkAccessibility, helper = helper, cached = lookedUp
        // Shown on the Mac Screen page and in Settings: userVisible. One lane hop: the helper's
        // lookup (the first time), else this app's own checks.
        let local = try? await work.run(.userVisible, mayBlock: .system, { () -> LocalRead in
            if let found = cached ?? helper() { return .helper(found) }
            return .granted(screenRecording(), accessibility())
        })
        let granted: (Bool, Bool)?
        var found: MacScreenHelper?
        switch local {
        case let .helper(helper)?:
            found = helper
            lookedUp = .some(helper)
            granted = await helper.permissions().map { ($0.screenRecording, $0.accessibility) }
        case let .granted(screen, access)?:
            lookedUp = .some(nil)
            granted = (screen, access)
        case nil:
            granted = nil
        }
        guard let granted, read == reads else { return }
        grantHolderName = found?.name
        screenRecordingGranted = granted.0
        accessibilityGranted = granted.1
    }

    /// macOS's Screen Recording prompt for the helper (System Settings when macOS no longer prompts).
    public func requestScreenRecording() {
        request(screenRecording: true)
    }

    /// macOS's Accessibility prompt for the helper (System Settings when macOS no longer prompts).
    public func requestAccessibility() {
        request(screenRecording: false)
    }

    /// Accessibility for this app itself: the viewer's Send System Shortcuts tap
    /// (``MacScreenSystemShortcuts``) runs in the app, not in the helper.
    public func requestAppAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openSettings(screenRecording: false) }
    }

    private func request(screenRecording: Bool) {
        let helper = helper, cached = lookedUp
        // task-owner: one request; it ends with the helper's answer
        Task { [weak self, work] in
            guard let found = (try? await work.run(.userVisible, mayBlock: .system, { cached ?? helper() })) ?? nil else {
                self?.requestInApp(screenRecording: screenRecording)
                return
            }
            let answer = await found.request(screenRecording: screenRecording)
            guard let self else { return }
            // macOS prompts once per grant; until it is on, the pane to switch it on is open too.
            if (screenRecording ? answer?.screenRecording : answer?.accessibility) != true { openSettings(screenRecording: screenRecording) }
            await refreshPermissions()
        }
    }

    /// A build without the helper: this app's own prompt, as before the helper.
    private func requestInApp(screenRecording: Bool) {
        if screenRecording {
            if !CGRequestScreenCaptureAccess() { openSettings(screenRecording: true) }
        } else {
            requestAppAccessibility()
        }
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
