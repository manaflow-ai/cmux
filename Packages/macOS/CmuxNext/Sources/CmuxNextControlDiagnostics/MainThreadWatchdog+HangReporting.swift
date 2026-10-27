public import CmuxNextControl

/// The control socket's view of the watchdog (``MainThreadHangReporting``): every other member already
/// has the protocol's name and type.
extension MainThreadWatchdog: MainThreadHangReporting {
    public var stallThreshold: Duration { configuration.threshold }
}
