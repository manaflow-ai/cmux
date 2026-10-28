public import CmuxNextInput
internal import CmuxNextInputCore
internal import Foundation
internal import ObjectiveC

/// What window hit testing costs, per input event, per hit test and per `-hitTest:` implementation, for
/// `debug.input hittest` (MQ-hittest). Debug and bench builds only (`DEBUG || CMUX_BENCH_HOOKS`): no
/// other build compiles the hooks, and ``install()`` returns false there.
///
/// Nothing is hooked until someone asks: ``install()`` scans the loaded classes off the main thread, replaces
/// `-[NSView hitTest:]` and every subclass's own `hitTest:` with a recording one, and subscribes to the input tap to
/// bracket each event. Each ``report()`` while installed scans again when the runtime's class count changed since
/// (a framework loaded later, such as CEF, or a generic Swift view class registered on first use) and hooks the new
/// overrides. ``uninstall()`` stops recording at once, cancels the subscriptions and puts every original IMP
/// back. A build that never asks, or asked and uninstalled, runs AppKit's and the app's own IMPs and has no tap
/// subscription: no cost at all.
///
/// While installed, on the main thread:
/// - A hit test is one outermost `hitTest:` call (AppKit's from `-[NSWindow sendEvent:]`, cursor and drag
///   updates, or an app call). Its time and the views it visited go in ``HitTestAuditReport/hitTests``.
/// - An event is one dispatch through the input tap, from its observe stage to its dispatch end; its hit tests,
///   their summed time and views go in ``HitTestAuditReport/events``. A nested dispatch joins the outer event.
/// - A view is visited once per `hitTest:` sent to it: an override that calls `super` on the same view is not a
///   second visit, and the call counts at the receiver's most derived implementation only.
/// - Each implementation is a row: a class that defines `hitTest:` itself (an override), or, for a view that
///   inherits NSView's own, the view's class. A row's views are the views visited inside its calls, itself
///   included. Times include the recording hooks' own time for the nested visits.
/// - A row's p99 time and views are read per call and per event (its calls' sums in one event); one over the
///   ``HitTestAuditThresholds`` makes it costly. Each costly override is one fix (a region cache or an early
///   return) in ``HitTestAuditReport/costly``; a costly row of a class that inherits NSView's own has none.
///
/// Chrome's model: Blink caches its last hit test and records hits and misses only for measurement
/// (third_party/blink/renderer/core/layout/hit_test_cache.cc, `Event.HitTestValidity`), and viz answers hit tests
/// from a precomputed region list instead of walking a tree (components/viz/common/hit_test/hit_test_region_list.h).
/// This audit finds the views whose walk needs one of those.
///
/// Method IMPs are process-wide, so the app has one instance, made by the control wiring and handed to
/// `debug.input` (``HitTestAuditDebugRecorder``).
///
/// ```swift
/// let audit = HitTestAudit(input: services.inputTap)
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
    /// The tap whose dispatches are the events; nil records hit tests only.
    private let input: InputEventTap?
    private var eventSubscriptions: [InputSubscription] = []
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The ``classKey(_:)`` of each class to scan instead of every loaded class (tests).
    let onlyClassKeys: [UInt]?
    /// The hooks of the last install, kept so a reinstall reuses the blocks it made.
    var hooks: [HookEntry] = []
    /// The runtime's class count when the hooks' scan began.
    private var scannedClassCount: Int32?
    /// The state the last ``install()`` or ``uninstall()`` asked for.
    private var wantsInstalled = false
    /// A ``report()`` found classes loaded since the last scan: scan and hook them while installed.
    private var wantsRescan = false
    /// A ``converge()`` is running (it awaits the scan and the swap off main).
    private var isChanging = false
    #endif

    /// An audit of every loaded view class, timed on `CLOCK_UPTIME_RAW`.
    ///
    /// - Parameters:
    ///   - input: The app's one input tap: each of its dispatches is one event.
    ///   - thresholds: The limits a row is costly past.
    public convenience init(input: InputEventTap, thresholds: HitTestAuditThresholds = HitTestAuditThresholds()) {
        self.init(input: input, thresholds: thresholds, onlyClasses: nil, now: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) })
    }

    /// - Parameters:
    ///   - input: The tap whose dispatches are the events; nil for none.
    ///   - thresholds: The limits a row is costly past.
    ///   - onlyClasses: The classes to hook instead of every loaded `NSView` class (each where it defines
    ///     `hitTest:` itself); nil for every one.
    ///   - now: Nanoseconds now, on one monotonic clock.
    init(input: InputEventTap?, thresholds: HitTestAuditThresholds, onlyClasses: [AnyClass]?, now: @escaping () -> UInt64) {
        self.input = input
        self.thresholds = thresholds
        recorder = HitTestAuditRecorder(now: now)
        #if DEBUG || CMUX_BENCH_HOOKS
        onlyClassKeys = onlyClasses.map { classes in classes.map { type in HitTestAudit.classKey(type) } }
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

    /// Installs the hooks and the event brackets and starts recording from empty; true once recording. False, and
    /// nothing hooked, in a build without hooks. Called while another install or uninstall runs, it returns at once
    /// with the state now, and the running one carries out the latest call.
    @discardableResult
    public func install() async -> Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        wantsInstalled = true
        await converge()
        return isInstalled
        #else
        return false
        #endif
    }

    /// Stops recording now, cancels the event brackets and puts every original IMP back (off the main thread: each
    /// set flushes method caches). What was recorded stays readable in ``report()`` until the next ``install()``.
    /// Called while another install, uninstall or a report's rescan runs, it returns at once and the running one
    /// uninstalls.
    public func uninstall() async {
        #if DEBUG || CMUX_BENCH_HOOKS
        wantsInstalled = false
        await converge()
        #endif
    }

    /// Clears what was recorded; the hooks stay.
    public func reset() {
        recorder.clear()
    }

    /// The report: one copy of the samples on the main thread, the percentiles off it. While installed, it first
    /// hooks the overrides of classes loaded since the last scan.
    public func report() async -> HitTestAuditReport {
        #if DEBUG || CMUX_BENCH_HOOKS
        await hookClassesLoadedSinceScan()
        #endif
        return await HitTestAuditReport.making(from: snapshot(), thresholds: thresholds)
    }

    /// The samples recorded so far, copied.
    func snapshot() -> HitTestAuditSnapshot {
        recorder.snapshot(available: Self.isAvailable, installed: isInstalled, hookedImplementations: hookedImplementations)
    }

    /// A class's report name: `debug.input`'s stable class name (module-qualified, no generic arguments, no
    /// launch-dependent private context), a KVO subclass counted as the class it observes.
    static func name(of type: AnyClass) -> String {
        if String(cString: class_getName(type)).hasPrefix("NSKVONotifying_"), let observed = class_getSuperclass(type) {
            return DebugInputScrollViews.className(observed)
        }
        return DebugInputScrollViews.className(type)
    }

    /// A class's one identity here: its Objective-C class object, the same for a Swift metatype (`NSView.self`,
    /// `object_getClass(_:)`) and an entry of the runtime's class list (as `RenderStats.classKey(_:)`).
    nonisolated static func classKey(_ type: AnyClass) -> UInt {
        UInt(bitPattern: ObjectIdentifier(type as AnyObject))
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Installs or uninstalls until the state is the one last asked for, and rescans while installed when a report
    /// asked. One runs at a time: a call made while one runs leaves its wish in ``wantsInstalled`` or
    /// ``wantsRescan`` for the running one.
    private func converge() async {
        guard !isChanging else { return }
        isChanging = true
        // Each step ends one wish: a state change sets isInstalled, a scan clears wantsRescan.
        while wantsInstalled != isInstalled || (wantsRescan && isInstalled) {
            if wantsInstalled != isInstalled {
                if wantsInstalled { await installNow() } else { await uninstallNow() }
            } else {
                await hookLoadedClasses()
            }
        }
        wantsRescan = false
        isChanging = false
    }

    /// Asks for a rescan while installed over every loaded class, when the class count moved since the last scan.
    private func hookClassesLoadedSinceScan() async {
        guard isInstalled, onlyClassKeys == nil else { return }
        let count = await Self.loadedClassCount()
        guard isInstalled, count != scannedClassCount else { return }
        wantsRescan = true
        await converge()
    }

    private func installNow() async {
        guard !isInstalled else { return }
        await hookLoadedClasses()
        recorder.start()
        isInstalled = true
        subscribeToEvents()
    }

    /// Scans the classes and puts a hook on every `hitTest:` the scan found that runs its original (a kept hook
    /// stays as it is).
    private func hookLoadedClasses() async {
        wantsRescan = false
        let classCount = await Self.loadedClassCount()
        let definers = await Self.scanDefiners(onlyClassKeys: onlyClassKeys)
        hooks = makeHooks(for: definers)
        scannedClassCount = classCount
        await Self.swap(hooks, installing: true)
    }

    private func uninstallNow() async {
        guard isInstalled else { return }
        recorder.stop()
        isInstalled = false
        for subscription in eventSubscriptions { subscription.cancel() }
        eventSubscriptions.removeAll()
        await Self.swap(hooks, installing: false)
    }

    private func subscribeToEvents() {
        guard let input else { return }
        let classes = InputEventClasses.all.union(.tracking)
        let recorder = recorder
        eventSubscriptions = [
            input.subscribe(class: classes, phase: .observe) { _ in recorder.eventBegan() },
            input.observeDispatchEnd(classes) { _, _ in recorder.eventEnded() },
        ]
    }
    #endif
}

/// The limits a ``HitTestAuditReport/Row`` is costly past (MQ-hittest: p99 over 20 us, or over 32 views, per call
/// or per event).
public nonisolated struct HitTestAuditThresholds: Sendable, Equatable, Codable {
    /// A row is costly when its p99 time, per call or per event, is over this.
    public var p99NanosOver: UInt64
    /// A row is costly when its p99 views, per call or per event, is over this.
    public var p99ViewsOver: UInt64

    public init(p99NanosOver: UInt64 = 20_000, p99ViewsOver: UInt64 = 32) {
        self.p99NanosOver = p99NanosOver
        self.p99ViewsOver = p99ViewsOver
    }

    private enum CodingKeys: String, CodingKey {
        case p99NanosOver = "p99_ns_over"
        case p99ViewsOver = "p99_views_over"
    }
}

/// `debug.input` action `hittest`: the first request installs the audit's hooks and answers the
/// empty report; each later one answers what was recorded since that install. `reset` uninstalls and clears, so
/// the next request installs again. `since_launch` changes nothing: recording starts at the install.
///
/// ```swift
/// DebugInput(sources: sources, recorders: [HitTestAuditDebugRecorder(audit: HitTestAudit(input: services.inputTap))])
/// ```
public nonisolated struct HitTestAuditDebugRecorder: DebugInputRecorder {
    private let audit: HitTestAudit

    /// - Parameter audit: The app's one audit (its hooks are process-wide).
    public init(audit: HitTestAudit) {
        self.audit = audit
    }

    public var kind: DebugInputRecorderKind { .hittest }

    public func rows(sinceLaunch: Bool) async -> HitTestAuditReport {
        await audit.installedReport()
    }

    public func reset() async {
        await audit.uninstallAndClear()
    }
}

extension HitTestAudit {
    /// Installs on the first call (``install()``), then the report.
    func installedReport() async -> HitTestAuditReport {
        await install()
        return await report()
    }

    /// ``uninstall()``, then ``reset()``.
    func uninstallAndClear() async {
        await uninstall()
        reset()
    }
}
