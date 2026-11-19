import CmuxNextSettings
import CoreFoundation
import Dispatch
import Foundation
import ObjectiveC

/// `debug.commit_producers`: the time each synchronous producer of a frame takes on the main thread, per Core
/// Animation commit (the per-commit producer timer of the perf budget rows `terminal.commit.producer`,
/// `page.commit.producer` and `frame.commit.all_producers`, scripts/cmux-next/perf-budget-table.tsv; its bench is
/// scripts/cmux-next/page-frame-bench.py).
///
/// The producers it times:
///   - terminal: a terminal's display pass, `-[IOSurfaceLayer display]` (Ghostty's layer; the call
///     `TerminalDisplayProbe` times for the resize bench), keyed by the layer, so each terminal is one producer;
///   - page: a Chromium page's placement in the frame, `-[CEFHostView layout]` (its page frame, occlusion and clip,
///     the tracker update), keyed by the host view, so each page is one producer. A layer-hosted page's pixels come
///     from its own process (`CALayerHost`): that part costs the commit nothing on the main thread and is not timed.
///
/// A frame ends at the run-loop observer one order after Core Animation's commit (2,000,001, `CommitBoundary.order`;
/// `MotionCommitProbe` brackets the commit the same way): every producer call since the previous frame end is in that
/// frame. Per frame it keeps each producer's total and the sum of all of them; `stop` and `read` answer the count of
/// frames with any producer work and, per kind, the p50, p95 and max of one producer's time in one frame, and of all
/// producers of a frame together (`all`).
///
/// Stop conditions: the run-loop observer exists only from `start` to `stop`, and ends itself (disarmed) after
/// ``maxRecordNanos`` or ``capacity`` frames, so a bench that never stops leaves nothing running. The timed method
/// overrides stay for the process once installed and only forward while unarmed (a load and a branch per call).
@MainActor
final class CommitProducerProbe {
    nonisolated enum Kind: String, CaseIterable, Sendable { case terminal, page }

    static let maxRecordNanos: UInt64 = 600 * 1_000_000_000
    static let capacity = 100_000
    /// One after Core Animation's commit observer (order 2,000,000), as `CommitBoundary.order`.
    static let frameEndOrder: CFIndex = 2_000_001

    private var armed = false
    private var installed: Set<Kind> = []
    private var frameEnd: CFRunLoopObserver?
    private var startedAt: UInt64 = 0
    private var stoppedBy: String?
    /// The open frame: each producer's ms so far.
    private var open: [ObjectIdentifier: (kind: Kind, ms: Double)] = [:]
    /// Closed frames: one producer's ms in one frame, by kind, and each frame's sum.
    private var perProducer: [Kind: [Double]] = [:]
    private var perFrame: [Double] = []

    nonisolated init() {}

    /// `debug.commit_producers {action}`: "start", "stop", or anything else to read the record.
    func handle(action: String?) -> JSONValue {
        switch action ?? "read" {
        case "start":
            stop(reason: nil)
            open.removeAll()
            perProducer.removeAll()
            perFrame.removeAll()
            stoppedBy = nil
            for kind in Kind.allCases where install(kind) { installed.insert(kind) }
            startedAt = Self.now()
            armed = true
            armFrameEnd()
        case "stop":
            closeFrame()
            stop(reason: "stop")
        default:
            break
        }
        return report()
    }

    fileprivate func record(_ producer: ObjectIdentifier, kind: Kind, milliseconds: Double) {
        guard armed else { return }
        open[producer, default: (kind: kind, ms: 0)].ms += milliseconds
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private func armFrameEnd() {
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        // A run-loop observer: a commit has no async-native signal. It runs on the main thread (main run loop only).
        frameEnd = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, Self.frameEndOrder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.frameDidEnd() } // main-proof: an observer on the main run loop only
        }
        if let frameEnd { CFRunLoopAddObserver(CFRunLoopGetMain(), frameEnd, .commonModes) }
    }

    private func frameDidEnd() {
        closeFrame()
        if Self.now() - startedAt > Self.maxRecordNanos {
            stop(reason: "max_seconds")
        } else if perFrame.count >= Self.capacity {
            stop(reason: "capacity")
        }
    }

    private func closeFrame() {
        guard armed, !open.isEmpty else { return }
        var sum = 0.0
        for entry in open.values {
            perProducer[entry.kind, default: []].append(entry.ms)
            sum += entry.ms
        }
        perFrame.append(sum)
        open.removeAll(keepingCapacity: true)
    }

    private func stop(reason: String?) {
        if let frameEnd { CFRunLoopObserverInvalidate(frameEnd) }
        frameEnd = nil
        if armed, let reason { stoppedBy = reason }
        armed = false
    }

    private func report() -> JSONValue {
        var members: [String: JSONValue] = [
            "armed": .bool(armed),
            "installed": .array(installed.map(\.rawValue).sorted().map(JSONValue.string)),
            "frames": .number(Double(perFrame.count)),
            "seconds": .number(startedAt > 0 ? Double(Self.now() - startedAt) / 1e9 : 0),
            "all": Self.stats(perFrame),
        ]
        for kind in Kind.allCases { members[kind.rawValue] = Self.stats(perProducer[kind] ?? []) }
        if let stoppedBy { members["stopped_by"] = .string(stoppedBy) }
        return .object(members)
    }

    /// `{samples, p50_ms, p95_ms, max_ms}` of `values` (nearest rank).
    nonisolated static func stats(_ values: [Double]) -> JSONValue {
        let sorted = values.sorted()
        // Nearest rank, in integers: the value at round(permille / 1000 * (count - 1)).
        func percentile(permille: Int) -> Double {
            sorted.dropFirst((permille * max(sorted.count - 1, 0) + 500) / 1000).first ?? 0
        }
        return .object(["samples": .number(Double(sorted.count)), "p50_ms": .number(percentile(permille: 500)),
                        "p95_ms": .number(percentile(permille: 950)), "max_ms": .number(sorted.last ?? 0)])
    }

    // MARK: - Timed overrides

    /// The class whose own method is timed for a kind. Only a class's own implementation is replaced, never an
    /// inherited one (replacing NSView's `layout` would time every view).
    private nonisolated static func target(_ kind: Kind) -> (AnyClass, Selector)? {
        switch kind {
        case .terminal: NSClassFromString("IOSurfaceLayer").map { ($0, #selector(TimedSelectors.display)) }
        case .page: NSClassFromString("CmuxNextBrowser.CEFHostView").map { ($0, #selector(TimedSelectors.layout)) }
        }
    }

    private func install(_ kind: Kind) -> Bool {
        if installed.contains(kind) { return true }
        guard let (cls, selector) = Self.target(kind), let method = Self.ownMethod(cls, selector) else { return false }
        typealias Call = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
        method_setImplementation(method, imp_implementationWithBlock(Self.timed(original, selector: selector, kind: kind, probe: self)))
        return true
    }

    /// The class's own implementation of `selector`, nil when it only inherits one (its superclass answers the same).
    private nonisolated static func ownMethod(_ cls: AnyClass, _ selector: Selector) -> Method? {
        guard let method = class_getInstanceMethod(cls, selector) else { return nil }
        let inherited = class_getSuperclass(cls).flatMap { class_getInstanceMethod($0, selector) }
        return method == inherited ? nil : method
    }

    /// Built outside the main actor so the block carries no isolation check of its own.
    private nonisolated static func timed(_ original: @escaping @convention(c) (AnyObject, Selector) -> Void, selector: Selector,
                                          kind: Kind, probe: CommitProducerProbe) -> @convention(block) (AnyObject) -> Void {
        { object in
            let start = DispatchTime.now().uptimeNanoseconds
            original(object, selector)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            MainActor.assumeIsolated { // main-proof: Core Animation display passes and AppKit layout run on the main thread
                probe.record(ObjectIdentifier(object), kind: kind, milliseconds: milliseconds)
            }
        }
    }
}

/// The timed methods' selectors (`-[CALayer display]`, `-[NSView layout]`), named without AppKit or a string lookup.
@objc private protocol TimedSelectors {
    func display()
    func layout()
}
