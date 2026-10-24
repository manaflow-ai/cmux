import CmuxNextCompat

/// When the launch drops the panes' last frames no pane took (the app's `LaunchFiles.release`, each
/// ``SavedFrameDirectory/release()``), at one launch
/// end that always comes: once each of this Mac's restored windows that has a workspace to show
/// installed its first content (then every pane they show presented its selection,
/// `ContentPresentationScheduler.whenIdle`, which `release` waits for), or when the local daemon is
/// unavailable, before or after the restore. A window with nothing to show (the launch window whose
/// workspace the daemon failed to create keeps the startup state) never holds them, and one that
/// closes counts as done. Runs `release` once. The app's window manager owns one and forwards its
/// window events to it.
///
/// ```swift
/// let release = LaunchFrameRelease(daemonUnavailable: { daemon.startup.isUnavailable }) {
///     presentation.whenIdle { launchFiles.release() }
/// }
/// release.restoreEnded(windows)   // the restore's windows
/// release.windowDone(id)          // a window installed its first content, or closed
/// ```
@MainActor
public final class LaunchFrameRelease {
    /// A window when the restore ended.
    public struct Window: Equatable, Sendable {
        /// The window's id.
        public let id: String
        /// It installed workspace content already.
        public let showsContent: Bool
        /// It shows this Mac's workspaces (another machine's may never answer).
        public let isLocal: Bool
        /// One of its workspaces is mirrored, so it will install content.
        public let hasWorkspaceToShow: Bool

        /// A window as the restore left it.
        public init(id: String, showsContent: Bool, isLocal: Bool, hasWorkspaceToShow: Bool) {
            (self.id, self.showsContent, self.isLocal, self.hasWorkspaceToShow) = (id, showsContent, isLocal, hasWorkspaceToShow)
        }
    }

    private let release: @MainActor () -> Void
    /// The restored windows that have not installed content yet; nil until the restore ended.
    private var awaiting: Set<String>?
    /// Whether `release` ran.
    public private(set) var isReleased = false
    private var unavailableWatch: Task<Void, Never>?

    /// Starts watching the daemon now.
    /// - Parameters:
    ///   - daemonUnavailable: Whether the local daemon is unavailable (observed).
    ///   - release: Drops the frames; called once.
    public init(daemonUnavailable: @escaping @MainActor @Sendable () -> Bool, release: @escaping @MainActor () -> Void) {
        self.release = release
        // task-owner: one observation per launch; it ends at the release (cancelled there)
        unavailableWatch = Task { [weak self] in
            for await unavailable in ObservationStream(daemonUnavailable) where unavailable {
                self?.releaseNow()
                return
            }
        }
    }

    /// The restore ended with `windows`: the frames go once each local one that has a workspace to
    /// show and no content yet showed it. The daemon stays watched until then: a window waiting on a
    /// daemon that goes away never shows its content.
    public func restoreEnded(_ windows: [Window]) {
        guard !isReleased else { return }
        awaiting = Set(windows.filter { !$0.showsContent && $0.isLocal && $0.hasWorkspaceToShow }.map(\.id))
        releaseWhenShown()
    }

    /// Window `id` installed its first content, or closed.
    public func windowDone(_ id: String) {
        if awaiting?.remove(id) != nil { releaseWhenShown() }
    }

    private func releaseWhenShown() {
        guard awaiting?.isEmpty == true else { return }
        releaseNow()
    }

    private func releaseNow() {
        guard !isReleased else { return }
        isReleased = true
        awaiting = nil
        unavailableWatch?.cancel()
        unavailableWatch = nil
        release()
    }
}
