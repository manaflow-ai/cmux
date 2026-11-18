public import AppKit
import CmuxNextCompat
import CmuxNextPages

/// A chat drawn before it shows (Leo 2026-11-17, on a Cloud chat's start: "when the machine gets
/// created, this whole chat thread blinks and loads again and then starts the response"). A Cloud
/// chat starts in a tab on this Mac and continues in a new tab on its machine; that tab's page loaded
/// only once it showed, so the thread went to the pane's loading cover and faded in again. The start
/// now draws the machine's page out of sight first, in the window the person looks at, as a kept or
/// spare page waits (``PageOffscreenParking``), and shows it once it painted: the pane takes a parked,
/// painted page as it is (`AgentTabContent`), with no cover and no fade.
extension AgentPaneView {
    static let paintParkingID = NSUserInterfaceItemIdentifier("agentPane.paintParked")

    /// Lays this page out of sight in `window` at `size` and returns once it painted, or false after
    /// `limit`. A page already in a pane, or one that painted, is left where it is.
    public func paintParked(in window: NSWindow, size: CGSize, within limit: Duration) async -> Bool {
        guard !model.hasPainted else { return true }
        guard superview == nil, let content = window.contentView, size.width > 0, size.height > 0 else { return false }
        let parking = content.subviews.first { $0.identifier == Self.paintParkingID } as? PageOffscreenParking ?? {
            let made = PageOffscreenParking()
            (made.identifier, made.autoresizingMask) = (Self.paintParkingID, [])
            content.addSubview(made, positioned: .below, relativeTo: nil)
            return made
        }()
        autoresizingMask = []
        parking.addSubview(self)
        parking.fit(to: size)
        isHidden = false
        PageWebView.syncChromiumVisibility(in: self)
        let model = model
        let watcher = Task { // on the main actor, as this view (no hop): it only reads `hasPainted`
            for await painted in ObservationStream({ model.hasPainted }) where painted { return true }
            return false // cancelled by the bound below
        }
        let bound = Task {
            // wakeup-allow: one-shot bound on a page's first paint before its chat shows anyway
            try? await Task.sleep(for: limit)
            watcher.cancel()
        }
        defer { bound.cancel() }
        return await withTaskCancellationHandler { await watcher.value } onCancel: { watcher.cancel() }
    }
}
