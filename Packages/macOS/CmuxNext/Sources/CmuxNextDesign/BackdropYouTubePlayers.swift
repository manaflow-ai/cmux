public import AppKit
import CmuxNextWakeups

/// The YouTube players behind every window, at most one playing app-wide: of the windows whose
/// YouTube wallpaper could play (seen, more than half visible, at least 200 pt a side, the Mac
/// affording it, someone at it), the frontmost one plays and every other shows the poster. One
/// player per video serves every window: it moves into the window that plays it and keeps its
/// place, so a second window never starts a second stream. A player no window can see for
/// ``releaseAfter`` is unloaded (its page closed, its web content process gone) and picks up at
/// the second it held when one is seen again. The image store owns the app's one
/// (``BackdropImageStore/youtube``).
@MainActor
public final class BackdropYouTubePlayers {
    /// How long a player no one can see stays loaded: the video wallpaper's minute.
    public var releaseAfter: Duration = .seconds(60)

    private struct Viewer {
        weak var view: BackdropYouTubeView?
        var video: BackdropYouTube
        /// Every term but the choice of window lets it play.
        var eligible: Bool
        var seen: Bool
        var window: Int
    }

    private struct Entry {
        var player: (any BackdropYouTubePlaying)?
        /// Where an unloaded player picks up.
        var resumeAt: Int?
        /// The embed refused the video: the poster stays.
        var failed = false
        let release: DemandTimer
    }

    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var entries: [String: Entry] = [:]
    /// The one viewer chosen to play now.
    public private(set) var chosen: ObjectIdentifier?
    private let clock: any Clock<Duration>
    private let make: @MainActor (BackdropYouTube, Int?) -> any BackdropYouTubePlaying
    private let order: @MainActor () -> [Int]
    /// Re-entrancy: a choice made while telling viewers about the last one waits for it.
    private var choosing = false

    /// - Parameters:
    ///   - clock: Times ``releaseAfter`` (tests step a manual one).
    ///   - order: The app's window numbers front to back (tests inject theirs).
    ///   - make: Makes a player of a video starting at a second (tests inject a fake).
    public init(clock: any Clock<Duration> = ContinuousClock(),
                order: @escaping @MainActor () -> [Int] = { NSApp?.orderedWindows.map(\.windowNumber) ?? [] },
                make: (@MainActor (BackdropYouTube, Int?) -> any BackdropYouTubePlaying)? = nil) {
        self.clock = clock
        self.order = order
        self.make = make ?? { video, resumeAt in BackdropYouTubePlayer(video: video, resumeAt: resumeAt) }
    }

    /// Players loaded now (tests).
    public var loadedCount: Int { entries.values.filter { $0.player != nil }.count }

    /// The player of `video`, if loaded (tests).
    public func player(of video: BackdropYouTube) -> (any BackdropYouTubePlaying)? { entries[video.id]?.player }

    /// Whether `video`'s embed refused it.
    public func failed(_ video: BackdropYouTube) -> Bool { entries[video.id]?.failed ?? false }

    /// Whether `view` is the one window chosen to play.
    func isChosen(_ view: BackdropYouTubeView) -> Bool { chosen == ObjectIdentifier(view) }

    /// `view` shows `video` in window `window`: `eligible` when it would play if chosen, `seen`
    /// when someone could see it. Chooses the window that plays and plays or holds each player.
    func report(_ view: BackdropYouTubeView, video: BackdropYouTube, window: Int, eligible: Bool, seen: Bool) {
        let key = ObjectIdentifier(view)
        let previous = viewers[key]?.video
        viewers[key] = Viewer(view: view, video: video, eligible: eligible, seen: seen, window: window)
        if let previous, previous != video { settle(previous) }
        choose()
        settle(video)
    }

    /// `view` no longer shows a YouTube video (another wallpaper, out of its window, closed).
    func leave(_ view: BackdropYouTubeView) {
        guard let viewer = viewers.removeValue(forKey: ObjectIdentifier(view)) else { return }
        if entries[viewer.video.id]?.player?.view.superview === view.playerHost { view.dropPlayer() }
        choose()
        // No window shows the video any more: unloaded now, like a closed window's decoder.
        if !viewers.values.contains(where: { $0.video == viewer.video }) {
            unload(viewer.video, forget: true)
        } else {
            settle(viewer.video)
        }
    }

    /// The frontmost eligible window plays; when that changes, the old and new choices ask again.
    private func choose() {
        let eligible = viewers.filter { $0.value.eligible && $0.value.view != nil }
        let front = order()
        let rank = { (window: Int) in front.firstIndex(of: window) ?? Int.max }
        let next = eligible.min { lhs, rhs in
            let (l, r) = (rank(lhs.value.window), rank(rhs.value.window))
            return l != r ? l < r : lhs.key.hashValue < rhs.key.hashValue
        }?.key
        guard next != chosen, !choosing else { return }
        let old = chosen
        chosen = next
        choosing = true
        for key in [old, next].compactMap({ $0 }) { viewers[key]?.view?.choiceChanged() }
        choosing = false
    }

    /// Plays `video` in the chosen window when it shows it, else holds it; loads it only to play,
    /// and counts the minute to unload while no window can see it.
    private func settle(_ video: BackdropYouTube) {
        var entry = entries[video.id] ?? Entry(release: DemandTimer(owner: "backdrop-youtube-release", clock: clock))
        let showing = viewers.values.filter { $0.video == video && $0.view != nil }
        let player = chosen.flatMap { key in viewers[key] }.flatMap { $0.video == video ? $0.view : nil }
        if let host = player, !entry.failed {
            if entry.player == nil {
                let made = make(video, entry.resumeAt)
                made.onEvent = { [weak self] event in self?.event(event, video: video) }
                entry.player = made
            }
            if let made = entry.player {
                host.adopt(made)
                made.play()
            }
        } else {
            entry.player?.pause()
        }
        if showing.contains(where: \.seen) || player != nil {
            entry.release.cancel()
        } else if entry.player != nil, !entry.release.isScheduled {
            // The minute counts from when the last window went out of sight.
            entry.release.schedule(after: releaseAfter) { @MainActor [weak self] in self?.releaseIfUnseen(video) }
        }
        entries[video.id] = entry
    }

    /// Unloads `video`'s player now if no window can see it (the release timer's work; tests).
    func releaseIfUnseen(_ video: BackdropYouTube) {
        guard !viewers.values.contains(where: { $0.video == video && $0.seen }) else { return }
        unload(video, forget: false)
    }

    private func unload(_ video: BackdropYouTube, forget: Bool) {
        guard var entry = entries[video.id] else { return }
        entry.release.cancel()
        if let player = entry.player {
            entry.resumeAt = player.position
            for viewer in viewers.values where player.view.superview === viewer.view?.playerHost { viewer.view?.dropPlayer() }
            player.close()
        }
        entry.player = nil
        entries[video.id] = forget ? nil : entry
    }

    private func event(_ event: BackdropYouTubePlayerEvent, video: BackdropYouTube) {
        switch event {
        case .playing:
            for viewer in viewers.values where viewer.video == video { viewer.view?.playerStarted() }
        case .failed:
            entries[video.id]?.failed = true
            unload(video, forget: false)
        }
    }
}
