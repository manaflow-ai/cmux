public import AppKit
import ApplicationServices
public import CmuxNextWakeups
import CmuxNextCompat
public import Observation
import SystemConfiguration

/// The permissions this Mac needs to share its screen through the device
/// hub ("Allow Mac Screen on this Mac", `MacScreenHubHost`): Screen
/// Recording (the picture) and Accessibility (the input). They belong to the
/// Screen Sharing helper (``MacScreenHelper``, plans/cmux-next/screen-sharing-helper.md),
/// the one app holding them for screen sharing and computer use: the reads and the
/// requests run in a fresh helper process, so macOS prompts for, lists and restarts
/// the helper, and a grant never relaunches this app. This app never reads or asks
/// for them for itself: a build without the helper shows both off and asks nothing.
/// Rechecked when the app becomes active (after System Settings). Link-mode
/// sharing (a pairing link anyone could use) is gone.
@Observable
public final class MacScreenShareHost {
    public private(set) var screenRecordingGranted = false
    public private(set) var accessibilityGranted = false
    /// The name System Settings lists the two grants under: the helper's
    /// ("cmux NIGHTLY Screen Sharing"), or nil while unknown and in a build
    /// without the helper (then this Mac cannot be shared).
    public private(set) var grantHolderName: String?
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    /// The helper's own grants, read by a fresh helper process (nil: it did not answer). A fresh
    /// process, because a long-running one can cache a Screen Recording denial after the person
    /// granted it in Settings. Tests replace it.
    @ObservationIgnored var readGrants: @Sendable (MacScreenHelper) async -> MacScreenHelper.Permissions? = {
        await $0.permissions()
    }
    /// This build's Screen Sharing helper (a disk lookup, run on the system lane); tests replace it.
    @ObservationIgnored var helper: @Sendable () -> MacScreenHelper? = { MacScreenHelper.bundled() }
    /// The helper once found; a build never gains or loses it.
    @ObservationIgnored private var found: MacScreenHelper?
    @ObservationIgnored private let work: BackgroundWork
    /// The number of reads started; a read applies its answer only when no later read has started.
    @ObservationIgnored private var reads: UInt64 = 0

    /// - Parameter work: the app's blocking-work lanes; the helper lookup runs on its system lane.
    public init(work: BackgroundWork) {
        self.work = work
    }

    /// Production callers that do not already own the app's shared blocking-work lanes.
    public convenience init() {
        self.init(work: BackgroundWork())
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
                self.releaseActivationWaiters()
            }
        }
    }

    /// Requests waiting for the person to come back to this app (``requestAndWait``).
    @ObservationIgnored private var activationWaiters: [CheckedContinuation<Void, Never>] = []

    private func releaseActivationWaiters() {
        let waiters = activationWaiters
        activationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Returns when this app is active: at once when it is, else at its next activation (this
    /// host's one activation observer, ``activate()``).
    private func nextActivationForReal() async {
        if activation == nil { activate() }
        await withCheckedContinuation { continuation in
            if isAppActive() { continuation.resume() } else { activationWaiters.append(continuation) }
        }
    }

    /// One `promptSettle` wait (a one-shot ``DemandTimer``, the timer CmuxNext uses).
    private func settleForReal(_ delay: Duration) async {
        let timer = DemandTimer(owner: "mac-screen.permission-prompt-settle")
        await withCheckedContinuation { continuation in
            timer.schedule(after: delay) { continuation.resume() }
        }
        _ = timer.isScheduled // keeps the timer (whose deinit cancels it) alive through the wait
    }

    /// Reads both of the helper's permissions off the main thread, from a fresh helper process,
    /// and shows them; a build without the helper shows both off. When reads
    /// overlap, the last one started decides (an older answer that arrives later is dropped).
    /// Cancellation changes nothing; an unavailable or failed read clears permission state rather
    /// than keeping an old grant.
    public func refreshPermissions() async {
        reads &+= 1
        let read = reads
        let helper = helper, readGrants = readGrants
        // Shown on the Mac Screen page and in Settings: userVisible.
        let holder = await lookUpHelper(helper)
        var granted: MacScreenHelper.Permissions?
        if let holder { granted = await readGrants(holder) }
        guard read == reads, !Task.isCancelled else { return }
        grantHolderName = holder?.name
        screenRecordingGranted = granted?.screenRecording ?? false
        accessibilityGranted = granted?.accessibility ?? false
    }

    /// The helper, found once on the system lane; nil in a build without one.
    private func lookUpHelper(_ helper: @escaping @Sendable () -> MacScreenHelper?) async -> MacScreenHelper? {
        if let found { return found }
        let looked = (try? await work.run(.userVisible, mayBlock: .system, { helper() })) ?? nil
        if let looked { found = looked }
        return looked
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
        // task-owner: one request; it ends when macOS's own surface is done with the person
        Task { [weak self] in await self?.requestAndWait(screenRecording: screenRecording) }
    }

    /// Asks macOS for one of the helper's grants and returns only once macOS's own surface is
    /// done with the person, then reads both grants fresh. A build without the helper asks
    /// nothing: no grant of this app serves Mac Screen. One prompt at a time: while macOS's "would like to record this computer's screen"
    /// prompt is up, no cmux sheet and no System Settings window joins it.
    ///
    /// macOS shows its prompt at most once per grant, and the prompt takes focus from this app.
    /// So when the request did not grant and this app is not active within ``promptSettle``, the
    /// prompt (or System Settings, opened from it) has the person, and this waits until they come
    /// back. When this app kept focus, macOS showed no prompt: System Settings' pane opens instead
    /// (behind this app; the caller's Check Again sheet is then the one prompt).
    public func requestAndWait(screenRecording: Bool) async {
        guard let granted = await (askMacOS ?? askMacOSForReal)(screenRecording) else { return await refreshPermissions() }
        if !granted {
            // The prompt may still be coming up: give it `promptSettle` to take focus.
            if isAppActive() { await (settle ?? settleForReal)(promptSettle) }
            if isAppActive() {
                (openSettingsPane ?? openSettings)(screenRecording)
            } else {
                await (nextActivation ?? nextActivationForReal)()
            }
        }
        await refreshPermissions()
    }

    /// How long after a request macOS's prompt may take to come up and take focus.
    @ObservationIgnored var promptSettle: Duration = .seconds(1)
    /// Whether this app has focus (macOS's prompt takes it); tests replace it.
    @ObservationIgnored var isAppActive: () -> Bool = { NSApplication.shared.isActive }
    /// Tests replace macOS's request (true when granted afterwards, nil with no helper), the Settings pane, the
    /// settle wait and the wait for this app's next activation.
    @ObservationIgnored var askMacOS: ((_ screenRecording: Bool) async -> Bool?)?
    @ObservationIgnored var openSettingsPane: ((_ screenRecording: Bool) -> Void)?
    @ObservationIgnored var settle: ((Duration) async -> Void)?
    @ObservationIgnored var nextActivation: (() async -> Void)?

    /// The helper's request; nil when this build carries no helper (then nothing is asked).
    private func askMacOSForReal(_ screenRecording: Bool) async -> Bool? {
        guard let found = await lookUpHelper(helper) else { return nil }
        let answer = await found.request(screenRecording: screenRecording)
        return (screenRecording ? answer?.screenRecording : answer?.accessibility) == true
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
