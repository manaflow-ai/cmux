#if DEBUG
internal import AppKit
internal import CMUXDebugLog

/// DEBUG probe that logs `runloop.stall` whenever the main run loop spends more
/// than the internal threshold between two consecutive observer activities.
///
/// This is a faithful lift of the former app-target `CmuxMainRunLoopStallMonitor`
/// final class. It attaches one `CFRunLoopObserver` (all activities, order
/// `CFIndex.max`) to the main run loop in `.commonModes`, tracks the previous
/// activity/timestamp, and emits a log line carrying the gap, the activity
/// transition, the current run-loop mode, the key window's first responder, and
/// the in-flight `NSApp.currentEvent`. The threshold (8 ms), the
/// beforeWaiting→afterWaiting suppression, and every log field are frozen.
///
/// The former `static let shared` singleton is gone: the app's composition root
/// constructs one instance and injects it as `any RunLoopStallMonitoring`.
///
/// Isolation: `@MainActor`. The probe genuinely lives on the main thread:
/// ``installIfNeeded()`` runs on the main actor at launch, and the observer is
/// attached to `CFRunLoopGetMain()`, so its callback is only ever delivered on
/// the main thread. The stall handler reads main-actor state (`NSApp.keyWindow`,
/// `NSApp.currentEvent`) and mutates the per-turn tracking fields, so co-locating
/// it on the main actor is the honest model rather than weakening Sendability.
/// The `CFRunLoopObserver` C callback is the one boundary: it is a C function
/// pointer that cannot be statically main-actor-isolated, so it re-enters the
/// known-main context via `MainActor.assumeIsolated`. This is the established
/// pattern for a main-run-loop C trampoline (the assertion always holds because
/// the observer runs on the main run loop) rather than manufacturing a private
/// isolation domain. The instance is held by the observer as an *unretained*
/// `info` pointer (matching the original `Unmanaged.passUnretained`); the
/// composition root owns the only strong reference for the app's lifetime, so
/// the observer never outlives it.
@MainActor
public final class CmuxMainRunLoopStallMonitor: RunLoopStallMonitoring {
    private let thresholdMs: Double = 8.0
    private var observer: CFRunLoopObserver?
    private var installed = false
    private var lastActivity: CFRunLoopActivity?
    private var lastTimestamp: TimeInterval?

    /// Creates a monitor. Call ``installIfNeeded()`` to attach the observer.
    public init() {}

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
                // The observer is attached to the main run loop, so this C
                // callback is always delivered on the main thread; re-enter the
                // known-main context to call the `@MainActor` handler.
                MainActor.assumeIsolated {
                    let monitor = Unmanaged<CmuxMainRunLoopStallMonitor>.fromOpaque(info).takeUnretainedValue()
                    monitor.handle(activity: activity)
                }
            },
            &context
        )

        guard let observer else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        installed = true
    }

    private func handle(activity: CFRunLoopActivity) {
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            lastActivity = activity
            lastTimestamp = now
        }

        guard let lastActivity, let lastTimestamp else { return }
        let elapsedMs = max(0, (now - lastTimestamp) * 1000.0)
        guard elapsedMs >= thresholdMs else { return }
        if lastActivity == .beforeWaiting && activity == .afterWaiting {
            return
        }

        let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { String(describing: $0) } ?? "nil"
        let firstResponder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let currentEvent = NSApp.currentEvent.map {
            "eventType=\($0.type.rawValue) keyCode=\($0.keyCode) mods=\($0.modifierFlags.rawValue)"
        } ?? "event=nil"
        logDebugEvent(
            "runloop.stall gapMs=\(String(format: "%.2f", elapsedMs)) prev=\(label(for: lastActivity)) " +
            "next=\(label(for: activity)) mode=\(mode) firstResponder=\(firstResponder) \(currentEvent)"
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
