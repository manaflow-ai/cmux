/// The host-application update actions the update pill and popover invoke, plus the log path
/// surfaced in error details.
///
/// This is the dependency-inversion seam between the update UI and the app: the views call up
/// through this protocol instead of reaching `AppDelegate` directly. The app's delegate
/// conforms and is passed into ``UpdatePill``.
@MainActor
public protocol UpdateActionsHost: AnyObject {
    /// Start a user-initiated check using the custom popover UI (the pill's primary action when
    /// a background update was detected but its details are not cached yet).
    func checkForUpdatesInCustomUI()

    /// Check for an update and auto-confirm the install if one is found (the
    /// "Install and Relaunch" action on the detected-update popover).
    func attemptUpdate()

    /// Install the currently available update through the shared update controller path.
    func installUpdate()

    /// The filesystem path of the update log, shown in the error popover's details block.
    var updateLogPath: String { get }
}
