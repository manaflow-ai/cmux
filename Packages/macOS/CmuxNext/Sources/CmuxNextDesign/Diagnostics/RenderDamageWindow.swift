public import AppKit
import CmuxNextWakeups

/// Ghostty's main-thread display passes (`-[IOSurfaceLayer display]`), counted by the App's
/// `debug.terminal_display` probe; ``RenderDamageWindow`` reads them through this seam. Arms nest,
/// so a window and a `debug.terminal_display` session never end or reset each other's counts.
@MainActor
public protocol DisplayPassSource: AnyObject {
    /// Passes counted while armed, since launch; it never goes down.
    var passCount: Int { get }
    /// Holds one arm (the first puts the probe on); false, holding nothing, when it cannot count.
    func armPasses() -> Bool
    /// Ends one arm (the last takes the probe off).
    func disarmPasses()
}

/// The render counts a ``RenderDamageWindow`` reads: the app's one ``RenderStats`` (a test passes a fake).
@MainActor
public protocol RenderCounting: AnyObject {
    /// Holds one arm (arms nest); false, holding nothing, in a build without hooks.
    func arm() -> Bool
    /// Waits for the queued hook work; true when the hooks count.
    func ready() async -> Bool
    /// Ends one arm.
    func disarm()
    var totals: RenderStats.Totals { get }
    func ownerTotals() -> [UInt: RenderStats.Totals]
    func owners() -> [RenderStats.Owner]
}

extension RenderStats: RenderCounting {}

/// `debug.damage {action: start | stop | read}`: render damage per owner class over one window,
/// for scripts/cmux-next/render-idle-damage.py, whose owner table is the MQ-damage-owners queue
/// (plans/cmux-next/chrome-parity/p03-rendering.md, R4 and task 003).
///
/// Chrome's model: `cc::DamageTracker` (cc/trees/damage_tracker.cc) names the layers that damaged a
/// frame, and `viz::DisplayDamageTracker` (components/viz/service/display/display_damage_tracker.cc)
/// draws nothing when no surface has damage. Here an owner's damage is its `updateLayer`/`draw(_:)`
/// calls plus its layer contents sets (``RenderStats``); an idle window should have none.
///
/// ``start()`` holds one arm of the app's one ``RenderStats`` (`debug.frames` nests its own) and returns
/// once the hooks count; the window's counts are differences from that moment. Ghostty's frames are the
/// contents sets of its layer owners (`ghosttyOwners`); its main-thread display passes come from the
/// ``DisplayPassSource``, of which the window holds one nested arm. ``stop()`` returns the report and
/// ends both arms; ``read()`` returns the window so far, or the last stopped one. A window ends by itself after ``maximumRun``.
/// In a build without the hooks (Release) every call returns ``Report/unavailable``.
@MainActor
public final class RenderDamageWindow {
    public static let maximumRun: Duration = .seconds(900)

    private let stats: any RenderCounting
    private let displayPasses: (any DisplayPassSource)?
    private let windows: @MainActor () -> [NSWindow]
    private let elapsed: @Sendable () -> Duration
    private let expiry: DemandTimer
    /// Owner names whose contents sets are Ghostty frames.
    public let ghosttyOwners: Set<String>
    private var holdsArm = false
    private var holdsPassArm = false
    private var current: Span?
    private var last: Report?

    /// The counts at ``start()``, to subtract.
    private struct Span {
        var owners: [UInt: RenderStats.Totals]
        var totals: RenderStats.Totals
        var started: Duration
        /// Display passes at ``start()``; nil when their probe could not be armed.
        var passes: Int?
    }

    /// - Parameters:
    ///   - stats: the app's one ``RenderStats`` (its hooks are process-wide).
    ///   - displayPasses: Ghostty's main-thread display passes (the App's `debug.terminal_display` probe).
    ///   - ghosttyOwners: owner names whose contents sets are Ghostty frames.
    ///   - windows: the windows read for hidden looping animations.
    ///   - clock: measures the window's seconds and its ``maximumRun``.
    public init(stats: any RenderCounting, displayPasses: (any DisplayPassSource)?, ghosttyOwners: Set<String>,
                windows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows },
                clock: any Clock<Duration> = ContinuousClock()) {
        self.stats = stats
        self.displayPasses = displayPasses
        self.ghosttyOwners = ghosttyOwners
        self.windows = windows
        elapsed = Self.stopwatch(clock)
        // timer-class-allow: a debug window's one 30 s backstop on the injected clock, made with AppControl before the app's deadline scheduler exists
        expiry = DemandTimer(owner: "debug.damage.expiry", clock: clock)
    }

    private nonisolated static func stopwatch<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
        let origin = clock.now
        return { origin.duration(to: clock.now) }
    }

    public var isRunning: Bool { current != nil }

    /// Opens a window (a `start` while one is open opens it again) once the hooks count.
    public func start() async -> Report {
        guard RenderStats.isAvailable else { return .unavailable }
        if !holdsArm { holdsArm = stats.arm() }
        let counting = await stats.ready()
        guard holdsArm, counting else {
            if current == nil { releaseArm() }
            return Report(error: "the render hooks are not counting (a stop came before they started)")
        }
        if !holdsPassArm, let displayPasses { holdsPassArm = displayPasses.armPasses() }
        current = Span(owners: stats.ownerTotals(), totals: stats.totals, started: elapsed(),
                       passes: holdsPassArm ? displayPasses?.passCount : nil)
        expiry.scheduleOnMain(after: Self.maximumRun) { [weak self] in _ = self?.stop() }
        return Report(running: true)
    }

    /// Closes the window: its report (kept for ``read()``), and the arm ends.
    public func stop() -> Report {
        guard RenderStats.isAvailable else { return .unavailable }
        expiry.cancel()
        guard let span = current else {
            releaseArm()
            return last ?? Report()
        }
        let report = measure(span, running: false)
        current = nil
        releaseArm()
        last = report
        return report
    }

    /// The open window so far, else the last stopped one.
    public func read() -> Report {
        guard RenderStats.isAvailable else { return .unavailable }
        guard let span = current else { return last ?? Report() }
        return measure(span, running: true)
    }

    private func releaseArm() {
        if holdsPassArm {
            holdsPassArm = false
            displayPasses?.disarmPasses()
        }
        guard holdsArm else { return }
        holdsArm = false
        stats.disarm()
    }

    private func measure(_ span: Span, running: Bool) -> Report {
        let names = Dictionary(stats.owners().map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
        // A count below the start mark is not a count of this window: no number rather than a wrong one.
        let passes: Int? = if let start = span.passes, let now = displayPasses?.passCount, now >= start { now - start } else { nil }
        let counts = Self.counts(start: span.owners, end: stats.ownerTotals(), totals: stats.totals - span.totals, names: names,
                                 seconds: (elapsed() - span.started) / .seconds(1), ghosttyOwners: ghosttyOwners,
                                 displayPasses: passes, hiddenLoops: RenderStats.hiddenLoopingAnimations(in: windows()))
        return Report(running: running, counts: counts)
    }

    /// An owner's damage: its `updateLayer`/`draw(_:)` calls and its layer contents sets.
    public nonisolated static func damage(_ totals: RenderStats.Totals) -> Int {
        totals[.damageRects] &+ totals[.contentsSets]
    }

    /// One window's counts: per owner (merged by name) the counts from `start` to `end`; owners with damage only.
    public nonisolated static func counts(start: [UInt: RenderStats.Totals], end: [UInt: RenderStats.Totals],
                                          totals: RenderStats.Totals, names: [UInt: String], seconds: Double,
                                          ghosttyOwners: Set<String>, displayPasses: Int?, hiddenLoops: [String: Int]) -> Counts {
        var byName: [String: RenderStats.Totals] = [:]
        for (key, now) in end {
            let delta = now - (start[key] ?? RenderStats.Totals())
            guard delta.calls > 0 else { continue }
            var sum = byName[names[key] ?? "unnamed"] ?? RenderStats.Totals()
            for counter in RenderStats.Counter.allCases { sum[counter] = sum[counter] &+ delta[counter] }
            byName[names[key] ?? "unnamed"] = sum
        }
        let owners = byName.filter { damage($0.value) > 0 }.map { Counts.Owner(name: $0.key, totals: $0.value) }.sorted { lhs, rhs in
            let (left, right) = (damage(lhs.totals), damage(rhs.totals))
            if left != right { return left > right }
            if lhs.totals[.damageArea] != rhs.totals[.damageArea] { return lhs.totals[.damageArea] > rhs.totals[.damageArea] }
            return lhs.name < rhs.name
        }
        let frames = byName.filter { ghosttyOwners.contains($0.key) }.reduce(0) { $0 &+ $1.value[.contentsSets] }
        return Counts(seconds: seconds, totals: totals, owners: owners, ghosttyFrames: frames, displayPasses: displayPasses,
                      hiddenLoops: hiddenLoops)
    }

    /// The counts of one window.
    public nonisolated struct Counts: Sendable, Equatable {
        public nonisolated struct Owner: Sendable, Equatable {
            public var name: String
            public var totals: RenderStats.Totals
        }

        public var seconds: Double
        /// All owners, damage or not.
        public var totals: RenderStats.Totals
        /// Owners with damage > 0, most first (then most area, then by name).
        public var owners: [Owner]
        public var ghosttyFrames: Int
        /// Ghostty's main-thread display passes in the window; nil when they could not be counted.
        public var displayPasses: Int?
        public var hiddenLoops: [String: Int]
    }

    /// One `debug.damage` reply.
    public nonisolated struct Report: Sendable, Equatable {
        public var available = true
        public var running = false
        public var error: String?
        /// Nil in a reply with no measured window (unavailable, not started, a `start`).
        public var counts: Counts?

        public init(available: Bool = true, running: Bool = false, error: String? = nil, counts: Counts? = nil) {
            self.available = available
            self.running = running
            self.error = error
            self.counts = counts
        }

        public static let unavailable = Report(available: false,
                                               error: "debug.damage needs the render hooks (a DEBUG or CMUX_BENCH_HOOKS build)")

        /// The reply as a `JSONSerialization` graph (render-idle-damage.py documents the same keys):
        /// `available`, `running`, `error`; with counts `seconds`, `totals` (every ``RenderStats/Counter`` key),
        /// `damage` and `damage_per_s` (all owners), `owners` (`owner`, `damage`, `damage_per_s` and each
        /// nonzero counter), `ghostty` (`frames`, `frames_per_s`, `display_calls`, NSNull when not counted),
        /// `hidden_looping_animations` and `hidden_looping_owners`.
        public var foundationObject: [String: Any] {
            var reply: [String: Any] = ["available": available, "running": running]
            if let error { reply["error"] = error }
            guard let counts else { return reply }
            func rate(_ count: Int) -> Double {
                counts.seconds > 0 ? (Double(count) / counts.seconds * 100).rounded() / 100 : 0
            }
            func keyed(_ totals: RenderStats.Totals, nonzeroOnly: Bool) -> [String: Any] {
                var keys: [String: Any] = [:]
                for counter in RenderStats.Counter.allCases where !nonzeroOnly || totals[counter] != 0 {
                    keys[counter.key] = totals[counter]
                }
                return keys
            }
            let damage = RenderDamageWindow.damage(counts.totals)
            reply["seconds"] = (counts.seconds * 1_000).rounded() / 1_000
            reply["totals"] = keyed(counts.totals, nonzeroOnly: false)
            reply["damage"] = damage
            reply["damage_per_s"] = rate(damage)
            reply["owners"] = counts.owners.map { owner -> [String: Any] in
                let damage = RenderDamageWindow.damage(owner.totals)
                return keyed(owner.totals, nonzeroOnly: true)
                    .merging(["owner": owner.name, "damage": damage, "damage_per_s": rate(damage)]) { _, new in new }
            }
            reply["ghostty"] = ["frames": counts.ghosttyFrames, "frames_per_s": rate(counts.ghosttyFrames),
                                "display_calls": counts.displayPasses.map { $0 as Any } ?? NSNull()] as [String: Any]
            reply["hidden_looping_animations"] = counts.hiddenLoops.values.reduce(0, +)
            reply["hidden_looping_owners"] = counts.hiddenLoops
            return reply
        }
    }
}
