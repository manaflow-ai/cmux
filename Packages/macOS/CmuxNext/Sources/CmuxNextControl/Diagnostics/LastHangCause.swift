/// What starts a local last-hang bundle (``MainThreadWatchdog/onLastHang``): task p09-observability-125's writer
/// copies every process's trace tail into `last-hang/<n>`, whatever hang-report consent and crash reporting say.
/// Chrome's `HangWatcher` dumps on its own watcher thread the same way (base/threading/hang_watcher.cc).
public enum LastHangCause: Sendable, Equatable {
    /// A watched thread's hang dump, as ``MainThreadWatchdog/onThreadHang`` gets it.
    case threadHang(ThreadHang)
}
