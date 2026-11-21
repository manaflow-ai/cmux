public import Foundation
public import CmuxNextDesign
import CmuxNextWakeups
import os

/// Drives a switching background (``BackdropSwitch``: a shuffle, a Time of Day schedule, a dynamic
/// wallpaper by the sun): shows its picture of now and turns to the next one when it changes, with
/// one timer armed to that change only, and decodes the next picture ``prewarmLead`` before.
///
/// The timers run on `ContinuousClock`, which counts time asleep, so a change that passed while the
/// Mac slept fires on wake with no wake observer. A day, time zone or clock change moves local
/// midnight and the sun, which an armed timer cannot see: the owner calls ``turn()`` on those.
@MainActor
public final class BackdropSwitchClock {
    /// Shows a picture (the owner's backdrop scope).
    private let show: (BackdropSelection?) -> Void
    private let turnTimer = DemandTimer(owner: "terminal-theme.daily-background")
    private let prewarmTimer = DemandTimer(owner: "terminal-theme.background-prewarm")
    /// The clock and calendar (read per pick, so a time zone change applies); tests pin both.
    public var now: () -> Date = Date.init, calendar: () -> Calendar = { .current }
    /// Decodes a picture the switch turns to next (tests record it).
    public var prewarm: (BackdropSelection) -> Void = { BackdropImageStore.shared.prewarm($0) }
    /// How long before a change the next picture starts decoding.
    public static let prewarmLead: TimeInterval = 30
    /// The switch followed; nil when the background does not switch.
    public private(set) var switching: BackdropSwitch?
    /// When the picture next changes (`debug.themes` `backdrop.next_change`); nil when the
    /// background does not switch or has no later change.
    public private(set) var nextChange: Date?
    /// Each dynamic wallpaper's frames, read once per path (its metadata, not a decode).
    private let knownFrames = OSAllocatedUnfairLock<[String: BackdropDynamicFrames?]>(initialState: [:])
    /// The shuffled folder's last listing and when it was read: the prewarm and the turn
    /// ``prewarmLead`` later walk the tree once, and a picture added since shows by the next turn.
    private let knownPictures = OSAllocatedUnfairLock<(path: String, read: ContinuousClock.Instant, pictures: [BackdropSelection])?>(
        initialState: nil)
    /// How long a folder's listing is reused: past the prewarm to its turn, well short of the
    /// shortest rotation (15 minutes).
    nonisolated static let picturesLifetime: Duration = .seconds(60)

    public init(show: @escaping (BackdropSelection?) -> Void) {
        self.show = show
    }

    /// Follows `next`, or shows `still` and stops when the background does not switch.
    public func follow(_ next: BackdropSwitch?, still: BackdropSelection?) {
        switching = next
        guard next == nil else { return turn() }
        stop()
        show(still)
    }

    /// Shows the switch's picture of `now()` and arms the next change (a second past it).
    public func turn() {
        guard let switching else { return }
        let date = now()
        let turn = switching.turn(at: date, calendar: calendar(), frames: frames(of:), pictures: pictures(in:))
        show(turn.picture)
        stop()
        nextChange = turn.next
        guard let next = turn.next else { return }
        let wait = max(1, next.timeIntervalSince(date) + 1)
        turnTimer.schedule(after: .seconds(wait)) { @MainActor [weak self] in self?.turn() }
        guard wait > Self.prewarmLead else { return }
        prewarmTimer.schedule(after: .seconds(wait - Self.prewarmLead)) { @MainActor [weak self] in
            guard let self, let upcoming = self.switching?.turn(at: next.addingTimeInterval(1), calendar: self.calendar(),
                                                                frames: self.frames(of:), pictures: self.pictures(in:)).picture
            else { return }
            self.prewarm(upcoming)
        }
    }

    private nonisolated func frames(of url: URL) -> BackdropDynamicFrames? {
        if let known = knownFrames.withLock({ $0[url.path] }) { return known }
        let read = BackdropDynamicFrames.read(contentsOf: url)
        knownFrames.withLock { $0[url.path] = .some(read) }
        return read
    }

    private nonisolated func pictures(in folder: URL) -> [BackdropSelection] {
        let now = ContinuousClock.now
        if let known = knownPictures.withLock({ $0 }), known.path == folder.path, now - known.read < Self.picturesLifetime {
            return known.pictures
        }
        let read = BackdropFolderPictures(folder: folder).list()
        knownPictures.withLock { $0 = (folder.path, now, read) }
        return read
    }

    private func stop() {
        turnTimer.cancel()
        prewarmTimer.cancel()
        nextChange = nil
    }
}
