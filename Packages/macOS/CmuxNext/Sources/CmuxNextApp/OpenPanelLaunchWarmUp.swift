import CmuxNextDesign

/// The made-ahead open panel's first warm-up at the launch's first idle moment (`LaunchSettle`), so the first click on
/// Home's "+", an agent's Add Files or Attach, or a page's file input is not cold, even before a view that offers the
/// picker reached a window (Lead decision 2026-10-23: keep the system panel; start its warm-up at launch idle). The
/// warm-up itself still waits for the person to pause and runs only while this account is the console user
/// (`OpenPanelWarmGate`).
@MainActor
struct OpenPanelLaunchWarmUp {
    /// The app's made-ahead panel (`AppServices.openPanel`).
    let openPanel: MadeAheadOpenPanel

    /// Starts the warm-up once `settle` settles (at once when it has).
    func schedule(on settle: LaunchSettle) {
        settle.whenSettled { [openPanel] in openPanel.warmWhenIdle() }
    }
}
