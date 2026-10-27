import Foundation

/// The release push (``ReleasePushListener``): a published build reaches this app within seconds,
/// not at the next scheduled read.
extension UpdaterService {
    /// Whether the push may run: the updater started with nothing disabling it,
    /// `updates.checkAutomatically` on, and the opt-in `updates.downloadAutomatically` on with found
    /// updates downloading by themselves now (the metered-network choice and the managed channel).
    var releasePushMayRun: Bool {
        isStarted && disabledReason == nil && tipCheck.automatic && downloadSetting.enabled && tipCheck.downloads(self)
    }

    /// Connects to the feed this app reads while the push may run, else stops it. Run when the
    /// updater starts, when the schedule, download or managed policy moves, and when the test feed changes.
    func refreshReleasePush() {
        let mayRun = releasePushMayRun
        releasePush.refresh(feedURL: mayRun ? (testFeedURL ?? identity.feed().url) : nil)
        if !mayRun { tipCheck.clearPushed() }
    }

    /// The app quits: the socket closes and nothing reconnects.
    public func stopReleasePush() {
        tipCheck.clearPushed()
        releasePush.stop()
    }

    /// A pushed build newer than the running one. Nothing staged: the fast check reads the feed now
    /// (``TipUpdateCheck/pushed(_:updater:)``) and starts the same check its interval would, so the
    /// build downloads, stages and installs by itself as a scheduled one does: nothing shows and the
    /// app is never brought forward. An update waiting: the staged build gives way to a newer one
    /// (``StagedUpdateRefresh``), as its scheduled probe would.
    func releasePushed(_ build: Int64) {
        guard releasePushMayRun else { return }
        if case .ready = flow.phase {
            stagedRefresh.run(reason: "release push", asked: false, updater: self)
        } else {
            tipCheck.pushed(String(build), updater: self)
        }
    }
}
