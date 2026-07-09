#if DEBUG
public import Foundation
internal import AppKit
internal import CMUXDebugLog

/// DEBUG probe that attributes main-run-loop turn time to named buckets and logs
/// a `main.turn.work` summary for turns that cross the internal thresholds.
///
/// This is a faithful lift of the former app-target `CmuxMainThreadTurnProfiler`
/// final class. It attaches one `CFRunLoopObserver` (all activities, order
/// `CFIndex.max`) to the main run loop: on `.entry`/`.afterWaiting` it starts a
/// turn and clears the buckets, on `.beforeWaiting`/`.exit` it flushes. Each
/// measured span is recorded via ``endMeasure(_:startedAt:)`` (forwarded from
/// ``CmuxTypingTiming/logDuration(path:startedAt:event:extra:)``). The flush
/// emits the top-8 buckets sorted by total/count, gated on a tracked-time
/// threshold (3 ms) or a sample-count threshold (16). Every threshold, the
/// sort/prefix ordering, and the log fields are frozen.
///
/// The former `static let shared` singleton and the static `endMeasure` entry
/// point are gone: the app's composition root constructs one instance, injects it
/// as `any MainThreadTurnProfiling`, and installs it as
/// ``CmuxTypingTiming/turnProfiler`` so `logDuration` reaches the same instance.
///
/// Isolation: nonisolated `final class`, `@unchecked Sendable`. It is not
/// `@MainActor` because ``endMeasure(_:startedAt:)`` is forwarded from
/// ``CmuxTypingTiming/logDuration(path:startedAt:event:extra:)`` on the typing
/// hot path, which is a nonisolated static API; an actor hop there is not
/// acceptable. Every mutation of the per-turn state (`turnStart`, `buckets`) is
/// nonetheless main-thread-confined: `endMeasure` early-returns unless
/// `Thread.isMainThread`, ``installIfNeeded()`` runs on the main actor at launch,
/// and `handle`/`flushTurn` run only from the observer attached to
/// `CFRunLoopGetMain()`. That single-thread confinement is why `@unchecked
/// Sendable` is sound here without locks. The `NSApp.*` reads inside the flush
/// happen on the main run loop, so they re-enter the known-main context via
/// `MainActor.assumeIsolated`. The `CFRunLoopObserver` holds the instance as an
/// *unretained* `info` pointer (matching the original
/// `Unmanaged.passUnretained`); the composition root owns the only strong
/// reference for the app's lifetime.
public final class CmuxMainThreadTurnProfiler: MainThreadTurnProfiling, @unchecked Sendable {
    private struct BucketStats {
        var count: Int = 0
        var totalMs: Double = 0
        var maxMs: Double = 0
    }

    private let trackedThresholdMs: Double = 3.0
    private let countThreshold: Int = 16
    // SAFETY: every read/write of the fields below happens on the main thread
    // (see the type's isolation note); no lock is required.
    private var observer: CFRunLoopObserver?
    private var installed = false
    private var turnStart: TimeInterval?
    private var buckets: [String: BucketStats] = [:]

    /// Creates a profiler. Call ``installIfNeeded()`` to attach the observer.
    public init() {}

    @inline(__always)
    public func endMeasure(_ bucket: String, startedAt: TimeInterval?) {
        guard let startedAt, CmuxTypingTiming.isEnabled, Thread.isMainThread else { return }
        let elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0)
        record(bucket: bucket, elapsedMs: elapsedMs, count: 1)
    }

    public func installIfNeeded() {
        guard CmuxTypingTiming.isEnabled else { return }
        guard !installed else { return }

        var context = CFRunLoopObserverContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        observer = CFRunLoopObserverCreate(
            kCFAllocatorDefault,
            CFRunLoopActivity.allActivities.rawValue,
            true,
            CFIndex.max,
            { _, activity, info in
                guard let info else { return }
                let profiler = Unmanaged<CmuxMainThreadTurnProfiler>.fromOpaque(info).takeUnretainedValue()
                profiler.handle(activity: activity)
            },
            &context
        )

        guard let observer else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        installed = true
    }

    private func handle(activity: CFRunLoopActivity) {
        let now = ProcessInfo.processInfo.systemUptime
        switch activity {
        case .entry, .afterWaiting:
            turnStart = now
            buckets.removeAll(keepingCapacity: true)
        case .beforeWaiting, .exit:
            flushTurn(at: now, nextActivity: activity)
        default:
            break
        }
    }

    private func record(bucket: String, elapsedMs: Double, count: Int) {
        if turnStart == nil {
            turnStart = ProcessInfo.processInfo.systemUptime
        }
        var stats = buckets[bucket, default: BucketStats()]
        stats.count += count
        stats.totalMs += elapsedMs
        stats.maxMs = max(stats.maxMs, elapsedMs)
        buckets[bucket] = stats
    }

    private func flushTurn(at now: TimeInterval, nextActivity: CFRunLoopActivity) {
        defer {
            turnStart = nil
            buckets.removeAll(keepingCapacity: true)
        }

        guard let turnStart else { return }
        guard !buckets.isEmpty else { return }

        let turnMs = max(0, (now - turnStart) * 1000.0)
        let trackedMs = buckets.values.reduce(0) { $0 + $1.totalMs }
        let totalCount = buckets.values.reduce(0) { $0 + $1.count }
        guard trackedMs >= trackedThresholdMs || totalCount >= countThreshold else { return }

        let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { String(describing: $0) } ?? "nil"
        // `flushTurn` runs only from the observer on the main run loop, so these
        // `NSApp` reads are on the main thread; re-enter the known-main context.
        let (firstResponder, eventSummary) = MainActor.assumeIsolated { () -> (String, String) in
            let responder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let summary = NSApp.currentEvent.map {
                "eventType=\($0.type.rawValue) keyCode=\($0.keyCode) mods=\($0.modifierFlags.rawValue)"
            } ?? "event=nil"
            return (responder, summary)
        }
        let bucketSummary = buckets
            .sorted {
                if abs($0.value.totalMs - $1.value.totalMs) > 0.01 {
                    return $0.value.totalMs > $1.value.totalMs
                }
                return $0.value.count > $1.value.count
            }
            .prefix(8)
            .map { key, value in
                if value.totalMs > 0.05 || value.maxMs > 0.05 {
                    return "\(key)=\(value.count)/\(String(format: "%.2f", value.totalMs))/\(String(format: "%.2f", value.maxMs))"
                }
                return "\(key)=\(value.count)"
            }
            .joined(separator: " ")

        logDebugEvent(
            "main.turn.work turnMs=\(String(format: "%.2f", turnMs)) trackedMs=\(String(format: "%.2f", trackedMs)) totalCount=\(totalCount) " +
            "next=\(label(for: nextActivity)) mode=\(mode) firstResponder=\(firstResponder) \(eventSummary) " +
            "\(bucketSummary)"
        )
    }

    private func label(for activity: CFRunLoopActivity) -> String {
        switch activity {
        case .entry:
            return "entry"
        case .beforeTimers:
            return "beforeTimers"
        case .beforeSources:
            return "beforeSources"
        case .beforeWaiting:
            return "beforeWaiting"
        case .afterWaiting:
            return "afterWaiting"
        case .exit:
            return "exit"
        default:
            return "unknown(\(activity.rawValue))"
        }
    }
}
#endif
