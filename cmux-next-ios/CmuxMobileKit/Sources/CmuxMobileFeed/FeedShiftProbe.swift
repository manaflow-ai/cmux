// DEBUG only: the Feed's frame-shift measure for FEED-15 (FeedArrivalShiftUITests).
#if DEBUG && os(iOS)
import CmuxMobileDesign
import CoreFoundation
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
/// A test may name the row to judge (`CMUX_MOBILE_FEED_SHIFT_WATCH=feed.row.<id>`): then that row is
/// judged instead of the top-most one, and a row below a resized row moving (SH-11 rule b) is not
/// counted. The rows above it are reported too
/// (`above=…`: the most any visible row above it moved), so a test of rule (b) checks both.
///
/// With the probe on, the rig's load waits for the test's signal: a Darwin notification
/// (`FeedShiftProbe.startSignal`, on CFNotificationCenter's Darwin center) the UI test posts once it has placed the list. XCUITest waits for
/// the app to go idle before each action, and a running load never lets it, so placing the list
/// under load took 40-118 s (feed15-red-2 c4876285); a timer could not know when placing ends. The
/// measure starts with the load. `CMUX_MOBILE_FEED_STRESS_HEADER=S`
/// shows and clears the Feed's refresh error every S seconds once the load starts: the header
/// changes height away from the top. The reading is the table's accessibility label:
/// `shift samples=… shifted=… max=… arrivals=…`.
@MainActor
final class FeedShiftProbe {
    static let shared = FeedShiftProbe()

    static let enabled = ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_SHIFT_PROBE"] == "1"
    /// The Darwin notification that starts the load and the measure (posted by the UI test).
    static let startSignal = "dev.cmux.mobile.feed-shift.start"
    /// What waits for the signal (the rig's live timer), run when it comes.
    private var onStart: [() -> Void] = []
    private var started = false
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
    /// The row a test named (`CMUX_MOBILE_FEED_SHIFT_WATCH`), else the top-most visible row.
    private var watched: String? = ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_SHIFT_WATCH"]
    /// The visible rows above the watched one, where they were on screen last frame.
    private var lastAbove: [String: CGFloat] = [:]
    private(set) var maxAbove: CGFloat = 0
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

    /// The Feed's table: the measure starts when the test's signal comes.
    func attach(_ table: UITableView) {
        guard Self.enabled, self.table == nil else { return }
        self.table = table
        lastOffset = table.contentOffset.y
        // A Darwin notification, which a UI test can post across processes. The callback may come
        // on any thread; it hops to the main actor. The probe is a process-long singleton, so the
        // unretained pointer outlives the observer.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                        { _, observer, _, _, _ in
                                            guard let observer else { return }
                                            let pointer = UInt(bitPattern: observer)
                                            DispatchQueue.main.async {
                                                MainActor.assumeIsolated {
                                                    guard let raw = UnsafeRawPointer(bitPattern: pointer) else { return }
                                                    Unmanaged<FeedShiftProbe>.fromOpaque(raw).takeUnretainedValue().start()
                                                }
                                            }
                                        },
                                        Self.startSignal as CFString, nil, .deliverImmediately)
    }

    /// Runs `body` when the test's signal comes (at once if it came already).
    func whenStarted(_ body: @escaping () -> Void) {
        if started { body() } else { onStart.append(body) }
    }

    private func start() {
        guard let table, !started else { return }
        started = true
        // A test may place the list a few points below the top (`CMUX_MOBILE_FEED_SHIFT_OFFSET=PT`):
        // a gesture that short reads as a tap on a row (green-43 RestJustBelowTop opened one).
        if let points = ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_SHIFT_OFFSET"].flatMap(Double.init) {
            table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top + CGFloat(points)), animated: false)
        }
        for body in onStart { body() }
        onStart = []
        measuring = true
        lastRows = rows(table)
        lastOffset = table.contentOffset.y
        token = FrameClock.shared.subscribe { [weak self] tick in self?.frame(at: tick.timestamp) }
        if let every = Self.headerEvery {
            let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.toggleHeader() }
            }
            RunLoop.main.add(timer, forMode: .common)
            headerTimer = timer
        }
        publish()
    }

    /// The header's refresh error shows and clears in turn (`CMUX_MOBILE_FEED_STRESS_HEADER`).
    private var headerShown = false
    private func toggleHeader() {
        headerShown.toggle()
        if headerShown { FeedStore.shared.setRefreshErrorForDemo() } else { FeedStore.shared.clearRefreshErrorForDemo() }
    }

    /// The list's own correction of the offset (keeping the read row in place): not the scroll.
    func correcting(_ body: () -> Void) {
        isCorrecting = true
        body()
        isCorrecting = false
        guard let table else { return }
        lastOffset = table.contentOffset.y
    }

    /// A drag begins (`scrollViewWillBeginDragging`): the pan's translation starts again from 0.
    /// Without this, the last drag's translation carried over when nothing scrolled between two
    /// drags (a drag that ends at rest, the held rows applied as a correction): the next drag's first
    /// move read as the whole last drag undone, about 290 pt (green-43 01d52643 Drag: 3 shifted
    /// frames, one per drag after the first, while its video shows no frame moving over 2 pt).
    func dragBegan() {
        lastTranslation = nil
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
        let rows = table.visibleCells.compactMap { cell -> (String, CGFloat)? in
            guard let id = cell.accessibilityIdentifier, id.hasPrefix("feed.row."), cell.frame.minY >= visibleTop - 0.5 else { return nil }
            return (id, cell.frame.minY)
        }
        let named = watched.flatMap { name in rows.first { $0.0 == name } }
        let read = named ?? rows.min { $0.1 < $1.1 }
        // The rows above the read row: none of them may move either (SH-11).
        if let read, !atEdge {
            var above: [String: CGFloat] = [:]
            for row in rows where row.1 < read.1 { above[row.0] = row.1 - table.contentOffset.y }
            for (id, y) in above { if let was = lastAbove[id] { maxAbove = max(maxAbove, abs((y - was) + explained)) } }
            lastAbove = above
        } else {
            lastAbove = [:]
        }
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
        table?.accessibilityLabel = String(format: "shift samples=%d shifted=%d max=%.2f arrivals=%d against=%d above=%.2f",
                                           samples, shiftedFrames, maxShift, arrivals, againstFrames, maxAbove)
    }
}
#endif
