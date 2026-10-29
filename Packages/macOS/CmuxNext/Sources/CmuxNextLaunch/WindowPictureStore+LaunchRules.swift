/// When a launch may show the front window's saved picture: never with
/// `launch.savedPicture` off, never after crash recovery (the pictures on disk are from a quit before the crashed
/// run, not of what it showed), never after a run that ended with no quit while its daemon kept running (the same
/// earlier quit's screens, under `relaunchReattach`: `RelaunchReattach.keepsSavedScreens`), never while the last run
/// may have left incognito workspaces, and never when the display, scale, appearance, theme, frame, sidebar width or
/// build differ from the window the launch opens. A changed sidebar or pane layout refuses only that region: it takes
/// today's path while the rest shows.
///
/// Chrome drops a startup capture on the same kinds of change: Android's paint preview is deleted when its version
/// or URL no longer matches (components/paint_preview/browser/paint_preview_base_service.cc) and is not shown after
/// an unclean exit (chrome/android/java/src/org/chromium/chrome/browser/paint_preview/StartupPaintPreviewHelper.java,
/// `isEnabled` checks the restore type).
///
/// ```swift
/// let facts = WindowPictureStore.LaunchFacts(savedPicture: settings.snapshot.savedPicture,
///                                            recovered: crashRecovery.recovery.isRestart,
///                                            incognitoLeftovers: incognitoLedger.mayHaveLeftovers)
/// if let shown = pictures.takeFront(matching: openingWindowMeta, launch: facts) {
///     // shown.picture.image as the first frame; shown.stale regions build live at once
/// }
/// ```
extension WindowPictureStore {
    /// What the launch knows of itself when it decides (the caller reads each; none of them is a disk call).
    public nonisolated struct LaunchFacts: Sendable, Equatable {
        /// `launch.savedPicture` (`LaunchSavedPictureSetting`).
        public var savedPicture: Bool
        /// The previous run ended in a crash this launch recovers from (`LaunchRecovery.isRestart`).
        public var recovered: Bool
        /// The last run may have left incognito workspaces (`IncognitoWorkspaceLedger.mayHaveLeftovers`: true too
        /// while its read runs or when it could not read the file).
        public var incognitoLeftovers: Bool
        /// The picture is an earlier quit's screens and the launch reattaches to the newer live ones
        /// (`!RelaunchReattach.keepsSavedScreens`: the previous run ended with no quit, as after `kill -9`).
        public var savedScreensStale: Bool

        public init(savedPicture: Bool, recovered: Bool, incognitoLeftovers: Bool, savedScreensStale: Bool = false) {
            (self.savedPicture, self.recovered, self.incognitoLeftovers) = (savedPicture, recovered, incognitoLeftovers)
            self.savedScreensStale = savedScreensStale
        }
    }

    /// Why the launch shows no saved picture.
    public nonisolated enum Refusal: String, Sendable, CaseIterable {
        case settingOff, crashRecovery, reattach, incognitoLeftovers
        /// A meta field of the whole picture differs from the window the launch opens (``WindowPictureMeta/Field``).
        case format, window, profile, frame, screen, scale, appearance, theme, sidebarWidth, build

        /// The launch mark that records it.
        public var mark: String { "launch_picture_refused.\(rawValue)" }

        /// The refusal for `field`; nil for a layout field, which refuses only its region.
        init?(_ field: WindowPictureMeta.Field) {
            switch field {
            case .format: self = .format
            case .window: self = .window
            case .profile: self = .profile
            case .frame: self = .frame
            case .screen: self = .screen
            case .scale: self = .scale
            case .appearance: self = .appearance
            case .theme: self = .theme
            case .sidebarWidth: self = .sidebarWidth
            case .build: self = .build
            case .sidebarLayout, .contentLayout: return nil
            }
        }
    }

    /// What the launch does with a saved picture.
    public nonisolated enum LaunchUse: Sendable, Equatable {
        /// Show it; the `stale` regions (their layout changed) are built live at once instead.
        case show(stale: Set<WindowPictureMeta.Region.Kind>)
        case refuse(Refusal)
    }

    /// Whether the picture `saved` describes may be the first frame of the window `opening` describes (the launch's
    /// meta of the window it opens, from the launch snapshot and the screen it opens on), given `launch`.
    public nonisolated static func use(_ saved: WindowPictureMeta, for opening: WindowPictureMeta, launch: LaunchFacts) -> LaunchUse {
        if !launch.savedPicture { return .refuse(.settingOff) }
        if launch.recovered { return .refuse(.crashRecovery) }
        if launch.savedScreensStale { return .refuse(.reattach) }
        if launch.incognitoLeftovers { return .refuse(.incognitoLeftovers) }
        let mismatches = saved.mismatches(opening)
        // In the fields' declared order, so one change always names the same reason.
        if let refusal = WindowPictureMeta.Field.allCases.lazy.filter(mismatches.contains).compactMap({ Refusal($0) }).first {
            return .refuse(refusal)
        }
        var stale: Set<WindowPictureMeta.Region.Kind> = []
        if mismatches.contains(.sidebarLayout) { stale.insert(.sidebar) }
        if mismatches.contains(.contentLayout) { stale.insert(.pane) }
        return .show(stale: stale)
    }

    /// The front window's picture with the regions to build live at once.
    public nonisolated struct ShownPicture: Sendable {
        public let picture: FrontPicture
        public let stale: Set<WindowPictureMeta.Region.Kind>
    }

    /// The front window's picture when ``use(_:for:launch:)`` allows it for `opening`, at once and never waiting:
    /// nil while the read runs, when the last quit saved none of that window, or once handed out or dropped. The
    /// only public way to the picture. A refused picture is handed to nobody and dropped, and its ``Refusal/mark``
    /// recorded.
    public func takeFront(matching opening: WindowPictureMeta, launch facts: LaunchFacts) -> ShownPicture? {
        guard let picture = launch.take() else { return nil }
        switch Self.use(picture.meta, for: opening, launch: facts) {
        case .show(let stale):
            return ShownPicture(picture: picture, stale: stale)
        case .refuse(let refusal):
            launch.note(refusal.mark)
            return nil
        }
    }
}
