import Foundation

/// The release push (``ReleasePushListener``): a published build reaches this app within seconds,
/// not at the next scheduled read.
extension UpdaterService {
    /// How soon another read follows one that did not reach the pushed build: the feed's edge may
    /// still answer with the build before it for a moment.
    static let releasePushRetryDelay: Duration = .seconds(20)
    /// How many reads look for a pushed build before the scheduled reads take over again.
    static let releasePushReads = 3

    /// Whether the push may run: the updater started with nothing disabling it,
    /// `updates.checkAutomatically` on, and the opt-in `updates.downloadAutomatically` on with found
    /// updates downloading by themselves now (the metered-network choice and the managed channel).
    var releasePushMayRun: Bool {
        isStarted && disabledReason == nil && tipCheck.automatic && downloadSetting.enabled && tipCheck.downloads(self)
    }

    /// Connects to the feed this app reads while the push may run, else stops it. Run when the
    /// updater starts, when the schedule, download or managed policy moves, and when the test feed changes.
    func refreshReleasePush() {
        let before = releasePush.feed
        releasePush.refresh(feedURL: releasePushMayRun ? (testFeedURL ?? identity.feed().url) : nil)
        // Stopped, or another feed (a test feed is never served): a pushed build waiting for its
        // read belongs to the feed it came from, so it is dropped.
        if releasePush.feed == nil || releasePush.feed != before { endReleasePushTarget() }
    }

    /// The app quits: the socket closes, the pending read is cancelled and nothing reconnects.
    public func stopReleasePush() {
        endReleasePushTarget()
        releasePush.stop()
    }

    /// A pushed build newer than the running one: read for it now (``advanceReleasePush()``).
    func releasePushed(_ build: Int64) {
        guard releasePushMayRun else { return }
        releasePushRetry.cancel()
        releasePushTarget = (String(build), Self.releasePushReads)
        advanceReleasePush()
    }

    /// The flow's phase moved: a pushed build that waited for a check, download or install to end
    /// is read for now.
    func followReleasePush() {
        guard releasePushTarget != nil, !releasePushRetry.isScheduled else { return }
        advanceReleasePush()
    }

    /// One read for the pushed build, through the paths the scheduled reads use, so the build
    /// downloads, stages and installs by itself as a scheduled one does: nothing shows and the app
    /// is never brought forward. Nothing found yet: the fast check reads the feed now
    /// (``TipUpdateCheck/readNow(_:)``) and starts the check its interval would. An update
    /// waiting: the staged build gives way to the newer one (``StagedUpdateRefresh``), as its
    /// scheduled probe would. A check, download or install in flight: it waits for the phase to
    /// move. Ends once the build was asked for or is staged, or after ``releasePushReads`` reads.
    func advanceReleasePush() {
        guard let target = releasePushTarget else { return }
        guard releasePushMayRun, !reached(target.build) else { return endReleasePushTarget() }
        guard !flow.installRequested, !isSheetPresented() else { return }
        let read: Bool
        switch flow.phase {
        case .hidden, .note:
            read = tipCheck.readNow(self)
        case .ready:
            read = stagedRefresh.run(reason: "release push", asked: false, updater: self) != nil
        case .checking, .downloading, .available, .installing:
            return
        }
        guard read else { return endReleasePushTarget() }
        log.append("release push: reading the feed for build \(target.build)")
        guard target.reads > 1 else { return endReleasePushTarget() }
        releasePushTarget = (target.build, target.reads - 1)
        releasePushRetry.schedule(after: Self.releasePushRetryDelay) { @MainActor [weak self] in
            self?.advanceReleasePush()
        }
    }

    /// Whether the pushed build is asked for or staged already (or this build is not older).
    private func reached(_ build: String) -> Bool {
        if !AppcastSelector.isOlder(identity.build, than: build) { return true }
        if let asked = tipCheck.asked, !AppcastSelector.isOlder(asked, than: build) { return true }
        if let staged = stagedBuild(), !AppcastSelector.isOlder(staged, than: build) { return true }
        return false
    }

    private func endReleasePushTarget() {
        releasePushTarget = nil
        releasePushRetry.cancel()
    }
}
