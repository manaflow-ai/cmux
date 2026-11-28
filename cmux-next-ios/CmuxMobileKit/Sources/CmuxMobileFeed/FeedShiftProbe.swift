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
/// A drag's translation is its own: it is forgotten in every frame no finger is down, so the next
/// drag's first move is never read against the last drag's travel (green-43: 3 frames of 290 pt
/// in Drag, the previous drag's 300 pt less the slop, with nothing moving on screen). A drag's
/// first move is the finger's by at most the finger's travel so far: an offset move past it (a
/// correction set while the finger rested, undone as the pan begins) is a shift.
///
/// A deceleration that undoes the list's correction reads as the scroll's own move, so the shift
/// would cancel out. Deceleration is smooth and one-way (UIKit slows it by `decelerationRate` each
/// millisecond): a frame that moves back against it (at any speed, the tail too), drops below half
/// the last frame's speed, or moves 2 pt more than its speed gives once the list looks still (under `stillSpeed`) is
/// a jump against the deceleration and counts as a shifted frame of its own. Every decelerating
/// frame's velocity is logged (category `feed-shift`), so such a frame shows in the app log's timeline.
///
/// `rest=` counts the shifted frames in which the list looked still: no finger travel, or a
/// deceleration under `stillSpeed` (a point a frame), or no motion at all. That is the jump in
/// Aziz's recording (109.59 s: the pill went 102 -> 103 and every row moved down one row, the list
/// still). The reading ends with the last notes (` | ` then one per shifted frame and per offset the
/// list set while UIKit moved it), so a failure says when and how.
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
/// changes height away from the top. `CMUX_MOBILE_FEED_SHIFT_PLACE=PT` places the list PT points
/// below its true top when the signal comes (a drag that short read as a hold on a row and opened
/// it: green-43 and feed15-red-7, RestJustBelowTop, "No matches found for Table").
/// `CMUX_MOBILE_FEED_SHIFT_ARRIVE=tail,touch` has the rig add one new row on top at the moment the
/// case is about (`onArrive`): `tail`, once per deceleration, when it slows under `stillSpeed` (the
/// list looks at rest while UIKit still moves it); `touch`, once per touch, a moment after a finger
/// comes down and before its pan begins (a finger resting, then creeping). The reading is the
/// table's accessibility label:
/// `shift samples=… shifted=… max=… arrivals=… against=… above=… rest=… arrived=… | notes`.
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
    /// Where the list is placed when the signal comes, in points below its true top.
    static let placeBelowTop: CGFloat? = ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_SHIFT_PLACE"]
        .flatMap(Double.init).map { CGFloat($0) }
    /// The moments the rig adds a row at (`tail`, `touch`).
    static let arriveOn = Set((ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_SHIFT_ARRIVE"] ?? "")
        .split(separator: ",").map(String.init))
    /// Under this speed (pt/s: a point a frame at 60 Hz) the list looks still.
    static let stillSpeed: CGFloat = 60
    /// The rig's one new row on top (FeedStressRig).
    var onArrive: (() -> Void)?

    private weak var table: UITableView?
    private var token: FrameClock.Token?
    private var measuring = false
    private var isCorrecting = false
    private var lastOffset: CGFloat = 0
    private var lastTranslation: CGFloat?
    /// The pan's translation at the last frame (a still finger: under half a point since).
    private var lastFrameTranslation: CGFloat?
    /// The way the last drag moved the offset (+1, -1): a deceleration after it goes the same way.
    private var dragDirection: CGFloat = 0
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
    /// The way this deceleration moves the offset (+1, -1; 0 until known).
    private var decelDirection: CGFloat = 0
    /// The last decelerating frames' speeds (pt/s), newest last, at most 3.
    private var recentSpeeds: [CGFloat] = []
    /// This deceleration's tail arrival was asked for; this touch's was.
    private var tailArrived = false
    private var touchDown: CFTimeInterval?
    private var touchArrived = false
    private(set) var againstFrames = 0
    private let log = Logger(subsystem: "dev.cmux.mobile", category: "feed-shift")
    private(set) var samples = 0
    private(set) var shiftedFrames = 0
    private(set) var restFrames = 0
    private(set) var maxShift: CGFloat = 0
    private(set) var arrivals = 0
    private(set) var arrived = 0
    private var notes: [String] = []
    private var startedAt: CFTimeInterval = 0
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
        if let below = Self.placeBelowTop {
            table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top + below), animated: false)
        }
        for body in onStart { body() }
        onStart = []
        measuring = true
        startedAt = CACurrentMediaTime()
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
        let before = table?.contentOffset.y ?? 0
        isCorrecting = true
        body()
        isCorrecting = false
        guard let table else { return }
        lastOffset = table.contentOffset.y
        // Set while UIKit moves the offset itself: the gesture or the deceleration may undo it.
        if measuring, table.isTracking || table.isDecelerating {
            note(String(format: "set %+.1f while %@", table.contentOffset.y - before,
                        table.isTracking ? "tracking (pan \(table.panGestureRecognizer.state.rawValue))" : "decelerating"))
        }
    }

    /// The offset moved (`scrollViewDidScroll`).
    func scrolled(_ scrollView: UIScrollView) {
        guard measuring else { return }
        let offset = scrollView.contentOffset.y
        defer { lastOffset = offset }
        if isCorrecting { return }
        let move = offset - lastOffset
        if scrollView.isTracking {
            let translation = scrollView.panGestureRecognizer.translation(in: scrollView).y
            if let previous = lastTranslation {
                // The finger moved the content down by its travel: the offset goes the other way.
                explained += -(translation - previous)
            } else {
                // The drag's first move (past the pan's slop): the offset follows the finger, by at most
                // its travel so far. The rest is not the scroll's.
                let travel = -translation
                explained += min(max(move, min(0, travel)), max(0, travel))
            }
            lastTranslation = translation
            if abs(move) > 0.5 { dragDirection = move > 0 ? 1 : -1 }
        } else {
            lastTranslation = nil
            // Deceleration, a jump, the rubber band: UIKit's own motion (the list's own sets are not
            // here: `correcting` took them out of the offset already).
            explained += move
            if scrollView.isDecelerating { decelMove += move }
        }
    }

    private func rows(_ table: UITableView) -> Int {
        table.numberOfSections > 1 ? table.numberOfRows(inSection: 1) : 0
    }

    private func frame(at now: CFTimeInterval) {
        guard let table else { return }
        if !table.isTracking {
            // No finger: the next drag's translation starts from zero.
            lastTranslation = nil
            touchDown = nil
            touchArrived = false
        }
        askForTouchArrival(table, at: now)
        let still = looksStill(table)
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
        let wasExplained = explained
        defer {
            explained = 0
            last = read.map { (id: $0.0, screenY: $0.1 - table.contentOffset.y) }
        }
        guard let read, let last, last.id == read.0, !atEdge else { return }
        let screenY = read.1 - table.contentOffset.y
        // The row's on-screen move, against the scroll's: content scrolled by `explained` moves rows by its negative.
        let rowShift = abs((screenY - last.screenY) + wasExplained)
        let shift = max(rowShift, againstShift)
        samples += 1
        if shift > 0.5 {
            shiftedFrames += 1
            if still { restFrames += 1 }
            let state = table.isTracking ? "drag" : table.isDecelerating ? "decel" : "rest"
            note(String(format: "shift %.1f (row %.1f, decel %.1f) %@%@ scroll %+.1f", shift, rowShift, againstShift, state,
                        still ? " still" : "", wasExplained))
        }
        if shift > maxShift { maxShift = shift }
        if samples % 10 == 0 || shift > 0.5 { publish() }
    }

    /// The list looks still this frame: a finger that has not moved half a point, a deceleration
    /// under `stillSpeed`, or no motion at all.
    private func looksStill(_ table: UITableView) -> Bool {
        if table.isTracking {
            let translation = table.panGestureRecognizer.translation(in: table).y
            defer { lastFrameTranslation = translation }
            return abs(translation - (lastFrameTranslation ?? translation)) < 0.5
        }
        lastFrameTranslation = nil
        if table.isDecelerating { return calm }
        return true
    }

    /// The last decelerating frames all moved under `stillSpeed`.
    private var calm: Bool { recentSpeeds.count >= 2 && recentSpeeds.allSatisfy { abs($0) < Self.stillSpeed } }

    /// `touch`: once per touch, 0.15 s after the finger comes down while its pan has not begun.
    private func askForTouchArrival(_ table: UITableView, at now: CFTimeInterval) {
        guard Self.arriveOn.contains("touch"), table.isTracking, table.panGestureRecognizer.state == .possible else { return }
        if touchDown == nil { touchDown = now }
        guard !touchArrived, let down = touchDown, now - down >= 0.15 else { return }
        touchArrived = true
        arrive("touch")
    }

    private func arrive(_ moment: String) {
        guard let onArrive else { return }
        arrived += 1
        note("arrive (\(moment))")
        onArrive()
    }

    /// A decelerating frame's move against the deceleration (a move back at any speed, a drop below
    /// half the last frame's speed, or more than 2 pt once the list looks still): its size, else 0.
    /// Logs each decelerating frame's velocity.
    private func checkDeceleration(_ table: UITableView, at now: CFTimeInterval) -> CGFloat {
        defer { decelMove = 0 }
        guard table.isDecelerating, !table.isTracking else {
            lastDecel = nil
            decelDirection = 0
            recentSpeeds = []
            tailArrived = false
            return 0
        }
        let move = decelMove
        // Which way it goes: the drag's way (a fling carries on), else its first move's.
        if decelDirection == 0 { decelDirection = dragDirection != 0 ? dragDirection : abs(move) > 0.5 ? (move > 0 ? 1 : -1) : 0 }
        let wasCalm = calm
        var against: CGFloat = 0
        var velocity: CGFloat?
        if let previous = lastDecel, now > previous.at {
            // Per second, so a long frame (two intervals' move in one) is not taken for a jump.
            let dt = now - previous.at
            let v = move / CGFloat(dt)
            velocity = v
            let reversed = decelDirection != 0 && move * decelDirection < -0.5
            let dropped = previous.velocity.map { abs($0) > 240 && abs(v) < abs($0) * 0.5 } ?? false
            // Still: a move 2 pt off what the last frame's speed gives (a long frame moves more, at that speed).
            let jumped = wasCalm && abs(move - (previous.velocity ?? 0) * CGFloat(dt)) > 2
            if reversed || dropped || jumped {
                against = abs(move - (previous.velocity ?? 0) * CGFloat(dt))
                againstFrames += 1
            }
            log.notice("FEEDSHIFT decel t=\(now, format: .fixed(precision: 3)) move=\(Double(move), format: .fixed(precision: 2)) v=\(Double(v), format: .fixed(precision: 1)) prev_v=\(Double(previous.velocity ?? 0), format: .fixed(precision: 1))\(against > 0 ? " AGAINST" : "", privacy: .public)")
        }
        if let velocity {
            recentSpeeds.append(velocity)
            if recentSpeeds.count > 3 { recentSpeeds.removeFirst() }
        }
        lastDecel = (move, now, velocity)
        // The tail: the list looks at rest while UIKit still moves it.
        if calm, !tailArrived, Self.arriveOn.contains("tail") {
            tailArrived = true
            arrive("tail")
        }
        return against
    }

    private func note(_ line: String) {
        notes.append(String(format: "%.2f ", CACurrentMediaTime() - startedAt) + line)
        if notes.count > 30 { notes.removeFirst(notes.count - 30) }
        publish()
    }

    private func publish() {
        let reading = String(format: "shift samples=%d shifted=%d max=%.2f arrivals=%d against=%d above=%.2f rest=%d arrived=%d",
                             samples, shiftedFrames, maxShift, arrivals, againstFrames, maxAbove, restFrames, arrived)
        table?.accessibilityLabel = notes.isEmpty ? reading : reading + " | " + notes.joined(separator: " ; ")
    }
}
#endif
