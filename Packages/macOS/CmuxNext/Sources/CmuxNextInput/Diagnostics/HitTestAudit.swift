import Foundation
import ObjectiveC

/// What window hit testing costs, per input event, per hit test and per `-hitTest:` implementation, for
/// `debug.input hittest` (p04-input-098, MQ-hittest). Debug and bench builds only (`DEBUG || CMUX_BENCH_HOOKS`): no
/// other build compiles the hooks, and ``install()`` returns false there.
///
/// Nothing is hooked until someone asks: ``install()`` scans the loaded classes off the main thread and replaces
/// `-[NSView hitTest:]` and every subclass's own `hitTest:` with a recording one; ``uninstall()`` stops recording at
/// once and puts every original IMP back. A build that never asks, or asked and uninstalled, runs AppKit's and the
/// app's own IMPs: no cost at all. The only call on the event path, ``eventBegan()``/``eventEnded()``, is one Bool
/// load while nothing is installed.
///
/// While installed, on the main thread:
/// - A hit test is one outermost `hitTest:` call (AppKit's from `-[NSWindow sendEvent:]`, cursor and drag
///   updates, or an app call). Its time and the views it visited go in ``HitTestAuditReport/hitTests``.
/// - An event is the span between ``eventBegan()`` and ``eventEnded()`` (the input tap brackets each dispatch);
///   its hit tests, their summed time and views go in ``HitTestAuditReport/events``.
/// - A view is visited once per `hitTest:` sent to it: an override that calls `super` on the same view is not a
///   second visit, and the call counts at the receiver's most derived implementation only.
/// - Each implementation is a row: a class that defines `hitTest:` itself (an override), or, for a view that
///   inherits NSView's own, the view's class. A row's views are the views visited inside its calls, itself
///   included. Times include the recording hooks' own time for the nested visits.
/// - A row whose p99 time or p99 views is over the ``HitTestAuditThresholds`` is costly; each costly row is one
///   fix (a region cache or an early return).
///
/// Chrome's model: Blink caches its last hit test and records hits and misses only for measurement
/// (third_party/blink/renderer/core/layout/hit_test_cache.cc, `Event.HitTestValidity`), and viz answers hit tests
/// from a precomputed region list instead of walking a tree (components/viz/common/hit_test/hit_test_region_list.h).
/// This audit finds the views whose walk needs one of those.
///
/// Method IMPs are process-wide, so the app has one instance, made by the composition root and handed to
/// `debug.input` and the input tap.
///
/// ```swift
/// let audit = HitTestAudit()
/// _ = await audit.install()
/// // ... a STRESS scroll and click bench ...
/// let json = try await audit.report().jsonData()
/// await audit.uninstall()
/// ```
public final class HitTestAudit {
    /// Whether this build has the hooks (`DEBUG || CMUX_BENCH_HOOKS`).
    public static var isAvailable: Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        true
        #else
        false
        #endif
    }

    /// The recording hooks are in place.
    public private(set) var isInstalled = false
    /// The limits a row is costly past.
    public var thresholds: HitTestAuditThresholds
    let recorder: HitTestAuditRecorder
    #if DEBUG || CMUX_BENCH_HOOKS
    /// Class pointers to scan instead of every loaded class (tests).
    let onlyClassKeys: [UInt]?
    /// The hooks of the last install, kept so a reinstall reuses the blocks it made.
    var hooks: [HookEntry] = []
    /// The last install or uninstall queued; each waits for the one before it.
    private var lastWork: Task<Void, Never>?
    #endif

    /// An audit timed on `CLOCK_UPTIME_RAW`, over every loaded view class.
    public convenience init(thresholds: HitTestAuditThresholds = HitTestAuditThresholds()) {
        self.init(thresholds: thresholds, onlyClasses: nil, now: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) })
    }

    /// - Parameters:
    ///   - thresholds: The limits a row is costly past.
    ///   - onlyClasses: The classes to hook instead of every loaded `NSView` class (each where it defines
    ///     `hitTest:` itself); nil for every one.
    ///   - now: Nanoseconds now, on one monotonic clock.
    init(thresholds: HitTestAuditThresholds, onlyClasses: [AnyClass]?, now: @escaping () -> UInt64) {
        self.thresholds = thresholds
        recorder = HitTestAuditRecorder(now: now)
        #if DEBUG || CMUX_BENCH_HOOKS
        onlyClassKeys = onlyClasses.map { classes in classes.map { type in unsafeBitCast(type, to: UInt.self) } }
        #endif
    }

    /// How many `hitTest:` implementations are hooked (NSView's own included).
    public var hookedImplementations: Int {
        #if DEBUG || CMUX_BENCH_HOOKS
        isInstalled ? hooks.count : 0
        #else
        0
        #endif
    }

    /// Installs the hooks and starts recording from empty; true once recording. False, and nothing hooked, in a
    /// build without hooks.
    @discardableResult
    public func install() async -> Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        await serially { await $0.installNow() }
        return isInstalled
        #else
        return false
        #endif
    }

    /// Stops recording now and puts every original IMP back (off the main thread: each set flushes method caches).
    /// What was recorded stays readable in ``report()`` until the next ``install()``.
    public func uninstall() async {
        #if DEBUG || CMUX_BENCH_HOOKS
        await serially { await $0.uninstallNow() }
        #endif
    }

    /// The input tap starts dispatching one event. One Bool load while nothing is installed.
    public func eventBegan() {
        guard isInstalled else { return }
        recorder.eventBegan()
    }

    /// The event ``eventBegan()`` started has been dispatched.
    public func eventEnded() {
        guard isInstalled else { return }
        recorder.eventEnded()
    }

    /// Clears what was recorded; the hooks stay.
    public func reset() {
        recorder.clear()
    }

    /// The report: one copy of the samples on the main thread, the percentiles off it.
    public func report() async -> HitTestAuditReport {
        await HitTestAuditReport.making(from: snapshot(), thresholds: thresholds)
    }

    /// The samples recorded so far, copied.
    func snapshot() -> HitTestAuditSnapshot {
        recorder.snapshot(available: Self.isAvailable, installed: isInstalled, hookedImplementations: hookedImplementations)
    }

    /// A class's report name; a KVO subclass counts as the class it observes.
    static func name(of type: AnyClass) -> String {
        if String(cString: class_getName(type)).hasPrefix("NSKVONotifying_"), let observed = class_getSuperclass(type) {
            return String(describing: observed)
        }
        return String(describing: type)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    private func serially(_ work: @escaping @MainActor (HitTestAudit) async -> Void) async {
        let previous = lastWork
        let task = Task {
            await previous?.value
            await work(self)
        }
        lastWork = task
        await task.value
    }

    private func installNow() async {
        guard !isInstalled else { return }
        let definers = await Self.scanDefiners(onlyClassKeys: onlyClassKeys)
        hooks = makeHooks(for: definers)
        await Self.swap(hooks, installing: true)
        recorder.start()
        isInstalled = true
    }

    private func uninstallNow() async {
        guard isInstalled else { return }
        recorder.stop()
        isInstalled = false
        await Self.swap(hooks, installing: false)
    }
    #endif
}

/// The limits a ``HitTestAuditReport/Row`` is costly past (MQ-hittest: p99 over 20 us, or over 32 views).
public nonisolated struct HitTestAuditThresholds: Sendable, Equatable, Codable {
    /// A row is costly when its p99 time is over this.
    public var p99NanosOver: UInt64
    /// A row is costly when its p99 views per call is over this.
    public var p99ViewsOver: UInt64

    public init(p99NanosOver: UInt64 = 20_000, p99ViewsOver: UInt64 = 32) {
        self.p99NanosOver = p99NanosOver
        self.p99ViewsOver = p99ViewsOver
    }

    enum CodingKeys: String, CodingKey {
        case p99NanosOver = "p99_ns_over"
        case p99ViewsOver = "p99_views_over"
    }
}
