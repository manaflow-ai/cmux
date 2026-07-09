/// The app-side seam ``BrowserDownloadActivityCoordinator`` drives for the live
/// effects it cannot own from the package: publishing the panel's
/// `@Published isDownloading`, and scheduling/reevaluating the hidden-web-view
/// discard. `BrowserPanel` conforms.
///
/// The coordinator owns the download tally and the `wasDownloading ->
/// isDownloading` edge math; the panel owns the only live witnesses, the
/// published `isDownloading` flag and the hidden-web-view discard scheduler,
/// which never cross the seam.
///
/// `@MainActor` because every member touches main-actor-bound panel state
/// (`@Published isDownloading`, the discard scheduler) and the host lives on
/// main, so each forward stays a plain main-actor call.
@MainActor
public protocol BrowserDownloadActivityHosting: AnyObject {
    /// Publishes the download-active flag (legacy `self.isDownloading = active`).
    func setDownloadingActive(_ active: Bool)

    /// Reevaluates hidden-web-view discard scheduling for `reason` (cancel when
    /// the web view is visible, otherwise schedule).
    func reevaluateHiddenWebViewDiscardScheduling(reason: String)

    /// Schedules a hidden-web-view discard for `reason` when the policy allows.
    func scheduleHiddenWebViewDiscardIfNeeded(reason: String)
}
