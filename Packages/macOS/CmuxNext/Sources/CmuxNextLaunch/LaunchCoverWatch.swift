public import AppKit
public import CmuxNextWakeups

/// Decides whether a launch ordered behind other apps' windows (`CMUX_NEXT_NO_ACTIVATE=1`) shows a window
/// (p08-startup-095). The occlusion read in the turn the windows were ordered in is not the system's answer yet:
/// AppKit reports it later with `NSWindow.didChangeOcclusionStateNotification`, as Chromium's
/// `WebContentsOcclusionCheckerMac` (content/app_shim_remote_cocoa/web_contents_occlusion_checker_mac.mm) follows
/// window occlusion by that notice. So the restore keeps its pane refs, and this watch reads ``LaunchWindowSight``
/// again at each occlusion notice of the launch windows and once at ``bound``:
///
/// - a window reported unoccluded, or one ordered in front: the person sees it; the watch ends and the pane refs
///   and the first frame decide;
/// - no window by current facts (the app hidden, each window closed or minimized): `covered` runs;
/// - every window covered, once each window's occlusion was reported or the bound passed: `covered` runs;
/// - windows still coming at the bound: the watch ends and the pane refs decide.
///
/// It decides once, and holds no ref: a launch whose refs all end first completes as before.
///
/// ```swift
/// // VisiblePaneRefs.watchCover(of:sight:startup:images:) makes and keeps it.
/// let watch = LaunchCoverWatch(deadlines: deadlines, sight: { readSight() }) {
///     paneRefs.launchShowedNoWindow(startup: startup, images: images)
/// }
/// watch.follow(launchWindows)
/// ```
@MainActor
public final class LaunchCoverWatch {
    /// How long after the restore the occlusion read is the system's: a window ordered in gets its occlusion
    /// report within a few frames.
    public nonisolated static let bound: Duration = .milliseconds(250)

    private let sight: @MainActor () -> LaunchWindowSight?
    private var covered: (@MainActor () -> Void)?
    /// The bound, in the visible class: a launch still launching admits it, and the person may be waiting.
    private let deadline: MainDeadline
    private var events: [EventSubscription] = []
    /// The launch windows whose occlusion the system has not reported since the restore.
    private var unreported: Set<ObjectIdentifier> = []

    /// - Parameters:
    ///   - deadlines: The app's deadline scheduler, where the bound goes.
    ///   - sight: The launch's sight now; nil ends the watch (its owner is gone).
    ///   - covered: Runs once when the launch shows no window.
    public init(deadlines: MainDeadlineScheduler, sight: @escaping @MainActor () -> LaunchWindowSight?,
                covered: @escaping @MainActor () -> Void) {
        deadline = MainDeadline(owner: "LaunchCoverWatch.bound", workClass: .visible, scheduler: deadlines)
        self.sight = sight
        self.covered = covered
    }

    /// True until the watch decided.
    public var isWatching: Bool { covered != nil }

    /// Watches `windows`' occlusion notices, and arms the bound.
    ///
    /// - Parameters:
    ///   - windows: The launch's windows ordered in.
    ///   - center: Where the windows post (tests pass their own; ``WindowEvents/of(_:center:)`` keeps the first).
    public func follow(_ windows: [NSWindow], center: NotificationCenter = .default) {
        guard isWatching else { return }
        unreported = Set(windows.map { ObjectIdentifier($0) })
        // raw-observer-allow: the WindowEvents subscription recipe R-notif asks for (one observer per window and notice); only the notice's name matches
        let occlusion = NSWindow.didChangeOcclusionStateNotification
        events = windows.map { window in
            let id = ObjectIdentifier(window)
            return WindowEvents.of(window, center: center).subscribe(occlusion, owner: "LaunchCoverWatch") { [weak self] in self?.reported(id) }
        }
        deadline.schedule(after: Self.bound) { [weak self] in self?.boundPassed() }
    }

    /// The bound passed: the occlusion read now is the system's.
    func boundPassed() {
        check(boundPassed: true)
    }

    private func reported(_ window: ObjectIdentifier) {
        unreported.remove(window)
        check(boundPassed: false)
    }

    private func check(boundPassed: Bool) {
        guard isWatching else { return }
        guard let sight = sight() else { return end(covered: false) }
        switch sight.verdict {
        case .noWindow: end(covered: true)
        case .shows: end(covered: false)
        case .mayBeCovered where sight.coming > 0: if boundPassed { end(covered: false) }
        case .mayBeCovered: if boundPassed || unreported.isEmpty { end(covered: true) }
        }
    }

    private func end(covered isCovered: Bool) {
        let action = covered
        covered = nil
        deadline.cancel()
        for subscription in events { subscription.cancel() }
        events = []
        if isCovered { action?() }
    }
}
