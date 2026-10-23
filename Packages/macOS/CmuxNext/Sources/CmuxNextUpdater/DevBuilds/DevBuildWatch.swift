import AppKit
import CmuxNextWakeups
public import Foundation

/// Offers a new Dev build on the bottom-left update card by itself (Leo 2026-10-23: "BUT i want
/// it to be auto suggesting on the bottom left... that's the point"), behind
/// `updates.offerDevBuilds` (off by default; "OPT IN i guess...").
///
/// Sparkle's own scheduled check runs at most hourly (its minimum interval), and Dev builds land
/// every few minutes. So on the Dev ring, while cmux is in front, this reads `dev-builds.json`
/// beside the appcast with a conditional GET (`If-None-Match`): a 304 costs one tiny request.
/// When the sidecar lists a build newer than the running and staged ones, it starts the check that
/// downloads that build and shows it as Update Ready: Sparkle's background check, or, while an
/// older build waits, the staged-update refresh that swaps it (``StagedUpdateRefresh``). One click
/// on the card installs and relaunches with every window, tab and chat restored, as for any update.
///
/// Stop condition and cleanup: the one-shot ``timer`` is armed only while the setting is on, the
/// ring is Dev, updates are not disabled and cmux is the active app. The first read is at once; each
/// changed sidecar resets the wait to ``baseInterval`` and each unchanged one doubles it, up to
/// ``maxInterval``. Resigning active cancels the timer; becoming active reads once (no sooner
/// than ``minimumReadSpacing`` after the last read). Turning the setting off or leaving the Dev ring
/// cancels the timer and both activation observations (they hold this object weakly and end at the
/// next notification once it is gone); a read in flight ends with its 15-second deadline.
@MainActor
public final class DevBuildWatch {
    public static let baseInterval: Duration = .seconds(180)
    public static let maxInterval: Duration = .seconds(1200)

    /// The conditional GET (replaced by tests).
    var fetcher: any ConditionalFetching = URLSessionConditionalFetcher()
    /// Starts the check that stages a newer build; nil picks it from the updater's phase.
    var startBackgroundCheck: (() -> Void)?
    /// Whether cmux is the active app (replaced by tests).
    var isAppActive: () -> Bool = { NSApplication.shared.isActive }
    /// A return to the front reads at once only this long after the last read.
    var minimumReadSpacing: Duration = .seconds(60)
    let timer: DemandTimer
    /// `updates.offerDevBuilds`.
    private(set) var enabled = false
    private var etag: String?
    private var interval = DevBuildWatch.baseInterval
    private var lastRead: Date?
    private var reading: Task<Void, Never>?
    /// The build a check was last started for, so one build starts one check.
    private(set) var offered: String?
    /// The builds `dev-builds.json` listed at its last changed read, newest first (the picker reads them).
    public private(set) var builds: [DevBuild] = []
    private var activation: [Task<Void, Never>] = []

    init(clock: any Clock<Duration>) {
        timer = DemandTimer(owner: "UpdaterService.devBuildWatch", clock: clock)
    }

    /// Follows the setting and the ring (``UpdaterService/configure``): reads at once when the watch turns on.
    func follow(enabled: Bool, updater: UpdaterService) {
        self.enabled = enabled
        guard runs(updater) else { return stop() }
        if activation.isEmpty { observeActivation(updater) }
        if reading == nil, !timer.isScheduled, isAppActive() { read(updater) }
    }

    /// cmux became or stopped being the active app.
    func appActivity(active: Bool, updater: UpdaterService) {
        guard active else { return timer.cancel() }
        guard runs(updater), reading == nil else { return }
        let since = lastRead.map { updater.now().timeIntervalSince($0) } ?? .infinity
        if since >= Double(minimumReadSpacing.components.seconds) {
            read(updater)
        } else if !timer.isScheduled {
            arm(updater, after: minimumReadSpacing - .seconds(since))
        }
    }

    private func runs(_ updater: UpdaterService) -> Bool {
        enabled && updater.ring == .dev && updater.disabledReason == nil
    }

    private func stop() {
        timer.cancel()
        activation.forEach { $0.cancel() }
        activation = []
    }

    private func arm(_ updater: UpdaterService, after delay: Duration) {
        timer.schedule(after: delay) { @MainActor [weak self, weak updater] in
            guard let self, let updater, self.runs(updater), self.isAppActive() else { return }
            self.read(updater)
        }
    }

    private func read(_ updater: UpdaterService) {
        guard let url = DevBuildsFeed.url(besideFeed: updater.testFeedURL ?? updater.identity.feed().url) else { return }
        timer.cancel()
        lastRead = updater.now()
        let fetcher = fetcher, etag = etag
        reading = Task { [weak self, weak updater] in
            let answer = await Task.detached { try? await fetcher.fetch(url, etag: etag) }.value
            guard let self else { return }
            self.reading = nil
            guard let updater else { return }
            self.finish(answer, updater: updater)
        }
    }

    private func finish(_ answer: ConditionalResponse?, updater: UpdaterService) {
        switch answer {
        case .changed(let data, let newTag)?:
            etag = newTag
            interval = Self.baseInterval
            if let feed = try? DevBuildsFeed.decode(data) {
                builds = feed.builds
                offer(feed, updater: updater)
            } else {
                updater.log.append("\(DevBuildsFeed.fileName) unreadable: nothing offered")
            }
        case .notModified?, nil:
            // Unchanged (or unreachable): the next read waits twice as long.
            interval = min(interval * 2, Self.maxInterval)
        }
        guard runs(updater), isAppActive() else { return }
        arm(updater, after: interval)
    }

    /// Starts the check for the newest listed build when it is newer than what runs and what waits.
    private func offer(_ feed: DevBuildsFeed, updater: UpdaterService) {
        guard let newest = feed.newest, newest.build != offered,
              newest.minimumSystemVersion.map({ SystemVersion.current >= $0 }) ?? true,
              AppcastSelector.isOlder(updater.identity.build, than: newest.build),
              updater.stagedBuild().map({ AppcastSelector.isOlder($0, than: newest.build) }) ?? true else { return }
        offered = newest.build
        updater.log.append("Dev build \(newest.build) (\(newest.sha.prefix(8))) is out: offering it on the card")
        if let startBackgroundCheck { return startBackgroundCheck() }
        if case .ready = updater.flow.phase {
            updater.stagedRefresh.run(reason: "new Dev build", updater: updater)
        } else {
            updater.controller?.checkInBackground(waitsForDeltas: false)
        }
    }

    private func observeActivation(_ updater: UpdaterService) {
        let names = [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)]
        activation = names.map { name, active in
            Task { [weak self, weak updater] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    guard let self, let updater else { return }
                    self.appActivity(active: active, updater: updater)
                }
            }
        }
    }
}
