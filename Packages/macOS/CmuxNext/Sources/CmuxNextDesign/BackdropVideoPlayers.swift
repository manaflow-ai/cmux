import AppKit
public import AVFoundation
public import CmuxNextCompat
public import CmuxNextWakeups

/// The looping players behind every video wallpaper, one per file, shared by every window that
/// shows it. A player runs while any of its windows wants it and pauses when none does. When none
/// of its windows can even be seen (hidden, covered, the screens asleep) for ``releaseAfter``, it
/// drops its items, which frees the decoder and its frame buffers, and picks up where it was when
/// one is seen again: hours behind other windows cost no video memory.
///
/// The composition root hands it the app's deadline scheduler and workspace notices once
/// (``follow(deadlines:session:)``): the release and each view's coverage samples are `background`
/// ``MainDeadline``s on the main thread's one wake-up queue (Chromium's `base::OneShotTimer` on a
/// typed task runner), and the session's resign and become-active notices reach every view through
/// one subscription each, not one observer per view.
@MainActor
public final class BackdropVideoPlayers {
    public static let shared = BackdropVideoPlayers()

    private struct Entry {
        let player: AVQueuePlayer
        /// Nil while released.
        var looper: AVPlayerLooper?
        var viewers: Set<ObjectIdentifier>
        var playing: Set<ObjectIdentifier>
        /// The viewers someone could see now.
        var seen: Set<ObjectIdentifier>
        /// Where a released player picks up.
        var resumeAt: CMTime = .zero
        /// A restored item still to be sought to ``resumeAt``, and the wait for it to be ready.
        var pendingRestore = false
        var restoring: NSKeyValueObservation?
        /// The release deadline, made when the player first goes out of sight (nil before, or with no scheduler).
        var release: MainDeadline?
    }

    private var entries: [URL: Entry] = [:]

    /// macOS Low Power Mode as the App's energy monitor reports it: every video holds its frame.
    public private(set) var lowPowerMode = false
    /// The thermal state as the App's energy monitor reports it: serious or worse holds every video.
    public private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    /// The views over these players, told when the two above change.
    private let views = NSHashTable<BackdropVideoView>.weakObjects()

    /// How long a player no one can see keeps its decoder.
    public var releaseAfter: Duration = .seconds(60)

    /// The app's deadline scheduler (``follow(deadlines:session:)``): the release and the views' coverage samples
    /// are deadlines on it. Nil keeps every decoder and samples no coverage.
    public private(set) var deadlines: MainDeadlineScheduler?

    /// The lanes a view lists the windows above it on (the app's, set at launch); nil samples no coverage.
    public var lanes: (any MayBlockRunner)?

    /// The login session is not the active one (fast user switching): every video holds its frame.
    public private(set) var sessionInactive = false
    private var sessionWatch: [EventSubscription] = []

    /// - Parameter deadlines: The deadline scheduler (tests pass a rig's); the app's comes through
    ///   ``follow(deadlines:session:)``.
    public init(deadlines: MainDeadlineScheduler? = nil) {
        self.deadlines = deadlines
    }

    /// Takes the app's deadline scheduler and follows the login session's resign and become-active notices
    /// (`session`: the NSWorkspace center's events). The composition root calls it once, before any window.
    public func follow(deadlines: MainDeadlineScheduler, session: AppEvents) {
        self.deadlines = deadlines
        sessionWatch = [
            session.subscribe(NSWorkspace.sessionDidResignActiveNotification, owner: "BackdropVideoPlayers") { [weak self] in
                self?.setSessionInactive(true)
            },
            session.subscribe(NSWorkspace.sessionDidBecomeActiveNotification, owner: "BackdropVideoPlayers") { [weak self] in
                self?.setSessionInactive(false)
            },
        ]
    }

    private func setSessionInactive(_ inactive: Bool) {
        guard inactive != sessionInactive else { return }
        sessionInactive = inactive
        for view in views.allObjects { view.inputsDidChange() }
    }

    /// Players alive now (tests).
    public var count: Int { entries.count }

    /// Sets Low Power Mode and the thermal state (the App, from its energy monitor, at launch and on
    /// each change) and updates every view over these players.
    public func setEnergy(lowPowerMode: Bool, thermal: ProcessInfo.ThermalState) {
        guard lowPowerMode != self.lowPowerMode || thermal != thermalState else { return }
        self.lowPowerMode = lowPowerMode
        thermalState = thermal
        for view in views.allObjects { view.inputsDidChange() }
    }

    /// Tells `view` when the energy inputs change, while it lives.
    func register(_ view: BackdropVideoView) {
        views.add(view)
    }

    /// Whether `url`'s player has given back its decoder (tests).
    public func isReleased(_ url: URL) -> Bool { entries[url].map { $0.looper == nil } ?? false }

    /// Whether `url`'s restored player is still waiting to seek back to its frame (tests).
    public func isRestoring(_ url: URL) -> Bool { entries[url]?.pendingRestore == true }

    func attach(_ url: URL, viewer: ObjectIdentifier) -> AVQueuePlayer {
        if var entry = entries[url] {
            entry.viewers.insert(viewer)
            entries[url] = entry
            return entry.player
        }
        let player = AVQueuePlayer()
        player.isMuted = true
        player.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .advance
        entries[url] = Entry(player: player, looper: Self.looper(url, player), viewers: [viewer], playing: [], seen: [])
        return player
    }

    func detach(_ url: URL, viewer: ObjectIdentifier) {
        guard var entry = entries[url] else { return }
        entry.viewers.remove(viewer)
        entry.playing.remove(viewer)
        entry.seen.remove(viewer)
        guard entry.viewers.isEmpty else {
            entries[url] = entry
            return apply(url)
        }
        // Torn down in idlesse's order: pause, stop looping, then drop the items.
        entry.release?.cancel()
        entry.restoring = nil
        entry.player.pause()
        entry.looper?.disableLooping()
        entry.player.removeAllItems()
        entries[url] = nil
    }

    func setPlaying(_ plays: Bool, seen: Bool = true, _ url: URL, viewer: ObjectIdentifier) {
        guard var entry = entries[url], entry.viewers.contains(viewer) else { return }
        if plays { entry.playing.insert(viewer) } else { entry.playing.remove(viewer) }
        if seen { entry.seen.insert(viewer) } else { entry.seen.remove(viewer) }
        entries[url] = entry
        apply(url)
    }

    /// Gives back `url`'s decoder now if no one can see it (the release timer's work; tests).
    func releaseIfUnseen(_ url: URL) {
        guard var entry = entries[url], entry.playing.isEmpty, entry.seen.isEmpty, let looper = entry.looper else { return }
        entry.resumeAt = entry.player.currentTime()
        entry.pendingRestore = false
        entry.restoring = nil
        entry.player.pause()
        looper.disableLooping()
        entry.player.removeAllItems()
        entry.looper = nil
        entries[url] = entry
    }

    private func apply(_ url: URL) {
        guard var entry = entries[url] else { return }
        if entry.seen.isEmpty, entry.looper != nil {
            // The minute counts from when the last viewer went out of sight, not from each update. Nobody sees the
            // release: background.
            if entry.release == nil, let deadlines {
                entry.release = MainDeadline(owner: "BackdropVideoPlayers.release", workClass: .background, scheduler: deadlines)
                entries[url] = entry
            }
            entry.release?.scheduleIfIdle(after: releaseAfter) { [weak self] in self?.releaseIfUnseen(url) }
        } else {
            entry.release?.cancel()
        }
        if entry.looper == nil, !entry.seen.isEmpty || !entry.playing.isEmpty {
            // Seen again: new items, at the exact frame it held once the first is ready (a seek
            // sent before then can be dropped, or undone by the looper).
            entry.looper = Self.looper(url, entry.player)
            entry.pendingRestore = true
            // Stored before observing: an item already ready reports inline, on this turn.
            entries[url] = entry
            let resumeAt = entry.resumeAt
            // raw-observer-allow: the player item's status has no notice; KVO is AVFoundation's only report of it,
            // held only while the restore's seek is still to come
            let observation = entry.player.observe(\.currentItem?.status, options: [.initial, .new]) { [weak self] player, _ in
                guard player.currentItem?.status == .readyToPlay else { return }
                // main-hop-allow: AVFoundation reports from its own queue: inline on main (the .initial report, this
                // turn), else one hop, once per restored item
                MainDelivery().run {
                    guard let self, let entry = self.entries[url], entry.pendingRestore else { return }
                    self.entries[url]?.pendingRestore = false
                    self.entries[url]?.restoring = nil
                    entry.player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            // Kept only while the seek is still to come (an inline report has already done it).
            if entries[url]?.pendingRestore == true { entries[url]?.restoring = observation }
            entry = entries[url] ?? entry
        }
        if entry.playing.isEmpty {
            if entry.player.rate != 0 { entry.player.pause() }
        } else if entry.player.rate == 0 {
            entry.player.play()
        }
    }

    /// A muted, looping item for `url` on `player`, with a short forward buffer.
    private static func looper(_ url: URL, _ player: AVQueuePlayer) -> AVPlayerLooper {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 0.5
        return AVPlayerLooper(player: player, templateItem: item)
    }
}
