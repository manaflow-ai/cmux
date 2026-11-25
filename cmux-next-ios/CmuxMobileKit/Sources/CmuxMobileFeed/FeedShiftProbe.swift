// DEBUG only: the Feed's frame-shift measure for FEED-15 (FeedArrivalShiftUITests).
#if DEBUG && os(iOS)
import CmuxMobileDesign
import OSLog
import QuartzCore
import UIKit

/// Measures whether rows arriving while the Feed is read move the row being read
/// (`CMUX_MOBILE_FEED_SHIFT_PROBE=1`). Every display frame it reads the read row (the first event
/// row whose top is on screen) and where it is on screen, and compares the move with what the
/// scroll explains: the finger's own travel while dragging (the pan's translation, not the offset,
/// so a correction the drag undoes is not taken for the person's scroll), the offset's move while
/// decelerating or jumping, less every offset the list sets itself (`correcting`: the anchor
/// restore, the header's compensation). A row that moves more than that moved for another reason:
/// the shift (acceptance SB: at most 0.5 pt in every frame, `shiftedFrames` 0). Frames at the very
/// top are not judged (new rows show there, FEED-15) nor at the bottom edge (the rubber band).
///
/// A deceleration that undoes the list's correction reads as the scroll's own move, so the shift
/// would cancel out. Deceleration is smooth (UIKit slows it by `decelerationRate` each millisecond):
/// a frame whose velocity reverses, or drops below half the last frame's, is a jump against
/// the deceleration and counts as a shifted frame of its own. Every decelerating frame's velocity is
/// logged (category `feed-shift`), so such a frame shows in the app log's timeline.
///
/// The rig's load waits `CMUX_MOBILE_FEED_STRESS_LIVE_DELAY` seconds (default 0), so a test can
/// place the list before rows arrive; the measure starts with it. `CMUX_MOBILE_FEED_STRESS_HEADER=S`
/// shows and clears the Feed's refresh error every S seconds once the load starts: the header
/// changes height away from the top. The reading is the table's accessibility label:
/// `shift samples=… shifted=… max=… arrivals=…`.
@MainActor
final class FeedShiftProbe {
    static let shared = FeedShiftProbe()

    static let enabled = ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_SHIFT_PROBE"] == "1"
    static let liveDelay: TimeInterval = ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_STRESS_LIVE_DELAY"].flatMap(Double.init) ?? 0
    static let headerEvery: TimeInterval? = ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_STRESS_HEADER"].flatMap(Double.init)

    private weak var table: UITableView?
    private var token: FrameClock.Token?
    private var measuring = false
    private var isCorrecting = false
    private var lastOffset: CGFloat = 0
    private var lastTranslation: CGFloat?
    /// The offset's move since the last frame that the scroll explains.
    private var explained: CGFloat = 0
    private var last: (id: String, screenY: CGFloat)?
    private var lastRows = 0
    /// The scroll's own offset move since the last frame while decelerating, and the last frame's.
    private var decelMove: CGFloat = 0
    private var lastDecel: (move: CGFloat, at: CFTimeInterval, velocity: CGFloat?)?
    private(set) var againstFrames = 0
    private let log = Logger(subsystem: "dev.cmux.mobile", category: "feed-shift")
    private(set) var samples = 0
    private(set) var shiftedFrames = 0
    private(set) var maxShift: CGFloat = 0
    private(set) var arrivals = 0
    private var headerTimer: Timer?

    /// The Feed's table: the measure starts when the rig's load does.
    func attach(_ table: UITableView) {
        guard Self.enabled, self.table == nil else { return }
        self.table = table
        lastOffset = table.contentOffset.y
        Timer.scheduledTimer(withTimeInterval: Self.liveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    private func start() {
        guard let table else { return }
        measuring = true
        lastRows = rows(table)
        lastOffset = table.contentOffset.y
        token = FrameClock.shared.subscribe { [weak self] tick in self?.frame(at: tick.timestamp) }
        if let every = Self.headerEvery {
            var shown = false
            let timer = Timer(timeInterval: every, repeats: true) { _ in
                MainActor.assumeIsolated {
                    shown.toggle()
                    if shown { FeedStore.shared.setRefreshErrorForDemo() } else { FeedStore.shared.clearRefreshErrorForDemo() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            headerTimer = timer
        }
        publish()
    }

    /// The list's own correction of the offset (keeping the read row in place): not the scroll.
    func correcting(_ body: () -> Void) {
        isCorrecting = true
        body()
        isCorrecting = false
        guard let table else { return }
        lastOffset = table.contentOffset.y
    }

    /// The offset moved (`scrollViewDidScroll`).
    func scrolled(_ scrollView: UIScrollView) {
        guard measuring else { return }
        let offset = scrollView.contentOffset.y
        defer { lastOffset = offset }
        if isCorrecting { return }
        if scrollView.isTracking {
            let translation = scrollView.panGestureRecognizer.translation(in: scrollView).y
            if let previous = lastTranslation {
                // The finger moved the content down by its travel: the offset goes the other way.
                explained += -(translation - previous)
            } else {
                // The drag's first move (past the pan's slop): taken as the scroll's.
                explained += offset - lastOffset
            }
            lastTranslation = translation
        } else {
            lastTranslation = nil
            // Deceleration, a jump, the rubber band: UIKit's own motion (the list's own sets are not
            // here: `correcting` took them out of the offset already).
            explained += offset - lastOffset
            if scrollView.isDecelerating { decelMove += offset - lastOffset }
        }
    }

    private func rows(_ table: UITableView) -> Int {
        table.numberOfSections > 1 ? table.numberOfRows(inSection: 1) : 0
    }

    private func frame(at now: CFTimeInterval) {
        guard let table else { return }
        let againstShift = checkDeceleration(table, at: now)
        let count = rows(table)
        if count > lastRows { arrivals += count - lastRows }
        lastRows = count
        let top = table.contentOffset.y + table.adjustedContentInset.top
        let maxOffset = table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom
        let atEdge = top <= 0.5 || table.contentOffset.y >= maxOffset - 0.5
        let visibleTop = table.contentOffset.y + table.adjustedContentInset.top
        let read = table.visibleCells
            .compactMap { cell -> (String, CGFloat)? in
                guard let id = cell.accessibilityIdentifier, id.hasPrefix("feed.row."), cell.frame.minY >= visibleTop - 0.5 else { return nil }
                return (id, cell.frame.minY)
            }
            .min { $0.1 < $1.1 }
        defer {
            explained = 0
            last = read.map { (id: $0.0, screenY: $0.1 - table.contentOffset.y) }
        }
        guard let read, let last, last.id == read.0, !atEdge else { return }
        let screenY = read.1 - table.contentOffset.y
        // The row's on-screen move, against the scroll's: content scrolled by `explained` moves rows by its negative.
        let shift = max(abs((screenY - last.screenY) + explained), againstShift)
        samples += 1
        if shift > 0.5 { shiftedFrames += 1 }
        if shift > maxShift { maxShift = shift }
        if samples % 10 == 0 || shift > 0.5 { publish() }
    }

    /// A decelerating frame's move against the deceleration (a reversal, or a drop below half the
    /// last frame's move): its size, else 0. Logs each decelerating frame's velocity.
    private func checkDeceleration(_ table: UITableView, at now: CFTimeInterval) -> CGFloat {
        defer { decelMove = 0 }
        guard table.isDecelerating, !table.isTracking else {
            lastDecel = nil
            return 0
        }
        let move = decelMove
        var against: CGFloat = 0
        var velocity: CGFloat?
        if let previous = lastDecel, now > previous.at {
            // Per second, so a long frame (two intervals' move in one) is not taken for a jump.
            let v = move / CGFloat(now - previous.at)
            velocity = v
            if let before = previous.velocity {
                let reversed = abs(before) > 30 && v * before < 0 && abs(move) > 0.5
                let dropped = abs(before) > 240 && abs(v) < abs(before) * 0.5
                if reversed || dropped {
                    against = abs(move - before * CGFloat(now - previous.at))
                    againstFrames += 1
                }
                log.notice("FEEDSHIFT decel t=\(now, format: .fixed(precision: 3)) move=\(Double(move), format: .fixed(precision: 2)) v=\(Double(v), format: .fixed(precision: 1)) prev_v=\(Double(before), format: .fixed(precision: 1))\(against > 0 ? " AGAINST" : "", privacy: .public)")
            }
        }
        lastDecel = (move, now, velocity)
        return against
    }

    private func publish() {
        table?.accessibilityLabel = String(format: "shift samples=%d shifted=%d max=%.2f arrivals=%d against=%d",
                                           samples, shiftedFrames, maxShift, arrivals, againstFrames)
    }
}
#endif
