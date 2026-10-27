public import CmuxNextSettings

/// What starts a local last-hang bundle (``LastHangBundles/trigger(_:)``, task p09-observability-125): the writer
/// copies every process's trace tail into `last-hang/<n>`, whatever hang-report consent and crash reporting say.
/// Chrome's `HangWatcher` dumps on its own watcher thread the same way (base/threading/hang_watcher.cc).
public enum LastHangCause: Sendable, Equatable {
    /// A watched thread's hang dump (p09-observability-068), as ``MainThreadWatchdog/onThreadHang`` gets it.
    case threadHang(ThreadHang)
    /// The main thread was busy this long, ``LastHangBundles/mainThreadHang`` or more: the watchdog's hang while it
    /// lasts, or a finished stall.
    case mainThreadHang(Duration)
    /// A committed key took this long to reach its frame (`key.frame`), more than ``LastHangBundles/slowKeyFrame``.
    case slowKeyFrame(Duration)

    /// The cause as the bundle's `manifest.json` and `trace.blackbox` name it: its `kind`, how long in
    /// `milliseconds`, and for a thread hang the registration, its kind and the thread's name.
    public var json: JSONValue {
        switch self {
        case .threadHang(let hang):
            ["kind": "thread_hang", "milliseconds": .number(Self.milliseconds(hang.overrun)), "thread": .string(hang.name),
             "thread_kind": .string(hang.kindName), "thread_name": .string(hang.threadName)]
        case .mainThreadHang(let duration):
            ["kind": "main_thread_hang", "milliseconds": .number(Self.milliseconds(duration))]
        case .slowKeyFrame(let duration):
            ["kind": "slow_key_frame", "milliseconds": .number(Self.milliseconds(duration))]
        }
    }

    /// `duration` in whole milliseconds.
    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return (Double(seconds) * 1_000 + Double(attoseconds) / 1e15).rounded(.down)
    }
}
