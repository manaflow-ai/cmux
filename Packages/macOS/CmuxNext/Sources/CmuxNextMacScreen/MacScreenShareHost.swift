public import AppKit
import CmuxNextCompat
public import Observation
import SystemConfiguration

/// The helper host's permission calls, as Mac Screen uses them: the grants cmux Computer Use
/// holds (a fresh probe process reads them), and macOS's request for one, made by the host
/// (`remote-host request …`), so macOS names cmux Computer Use. The app wires it
/// (``CmuxRemoteService``); tests replace it.
public nonisolated struct MacScreenHelperPermissions: Sendable {
    /// The grants now and the name System Settings lists them under; throws when the host does not answer.
    public var read: @Sendable () async throws -> (screen: Bool, control: Bool, holder: String?)
    /// Asks macOS for Screen Recording (true) or Accessibility (false) for the helper; the host
    /// opens the System Settings pane itself when macOS will not prompt again.
    public var request: @Sendable (_ screenRecording: Bool) async throws -> Void

    public init(read: @escaping @Sendable () async throws -> (screen: Bool, control: Bool, holder: String?),
                request: @escaping @Sendable (_ screenRecording: Bool) async throws -> Void) {
        self.read = read
        self.request = request
    }
}

/// The permissions this Mac needs to share its screen through the device
/// hub ("Allow Mac Screen on this Mac", `MacScreenHubHost`): Screen
/// Recording (the picture) and Accessibility (the input). They belong to
/// cmux Computer Use, the one helper whose Screen Sharing worker captures
/// every session (``MacScreenCaptureWorker``): the reads and the requests go
/// through its host (``MacScreenHelperPermissions``), so macOS prompts for,
/// lists and restarts the helper, a grant never relaunches this app, and this
/// app never asks macOS for either grant. Rechecked when the app becomes
/// active (after System Settings). Link-mode sharing (a pairing link anyone
/// could use) is gone.
@Observable
public final class MacScreenShareHost {
    public private(set) var screenRecordingGranted = false
    public private(set) var accessibilityGranted = false
    /// The name System Settings lists the two grants under ("cmux Computer Use"), or nil while
    /// unknown. The permission copy names it (``MacScreenGrantCopy``).
    public private(set) var grantHolderName: String?
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    /// The helper host's permission calls; nil until the app wires them (then both grants read as off).
    @ObservationIgnored public var helper: MacScreenHelperPermissions?
    /// The number of reads started; a read applies its answer only when no later read has started.
    @ObservationIgnored private var reads: UInt64 = 0

    public init() {}

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

    /// Reads both grants from the helper host (a fresh probe process there) and shows them. When
    /// reads overlap, the last one started decides (an older answer that arrives later is
    /// dropped). Cancellation changes nothing; an unavailable or failed read clears permission
    /// state rather than keeping an old grant.
    public func refreshPermissions() async {
        reads &+= 1
        let read = reads
        let answer = try? await helper?.read()
        guard read == reads, !Task.isCancelled else { return }
        grantHolderName = answer?.holder
        screenRecordingGranted = answer?.screen ?? false
        accessibilityGranted = answer?.control ?? false
    }

    /// macOS's Screen Recording prompt for cmux Computer Use (its System Settings pane when macOS no longer prompts).
    public func requestScreenRecording() {
        request(screenRecording: true)
    }

    /// macOS's Accessibility prompt for cmux Computer Use (its System Settings pane when macOS no longer prompts).
    public func requestAccessibility() {
        request(screenRecording: false)
    }

    private func request(screenRecording: Bool) {
        guard let helper else { return }
        // task-owner: one request through the helper host; it ends with the host's answer
        Task { [weak self] in
            try? await helper.request(screenRecording)
            await self?.refreshPermissions()
        }
    }

    /// The System Settings pane that lists the grant (no prompt: the person turns cmux Computer Use on there).
    public func openSettings(screenRecording: Bool) {
        let pane = screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.openInBackground(url) }
    }

    /// The Mac's name from Sharing settings (fast; no DNS).
    public static var computerName: String {
        MacName.captureOverride ?? (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }
}
