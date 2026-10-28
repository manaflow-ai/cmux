public import CmuxNextCompat
public import CmuxNextControl
public import CmuxNextTrace

extension DaemonService {
    /// This machine's daemon trace commands (`trace-start`, `trace-stop` and `trace-status`, p09-observability
    /// task 015) for the control socket's `trace.start` (task 020). Each call reads the connection current
    /// then, so a reconnect between a start and its stop still reaches the daemon.
    public var traceLink: DaemonTraceLink {
        DaemonTraceLink { [weak self] in await self?.connection }
    }

    /// `trace.start`, `trace.stop` and `trace.status` over the app's ring (`blackBox` maps the recording ring on
    /// `work`'s `.files` lane), this daemon and its children, and the secure-input gate. Chromium tracing (task
    /// 051), the typing flows (019) and the indicator (133) join ``TraceControlParts`` as they land; until then
    /// each reports `unsupported`.
    ///
    /// - Parameters:
    ///   - blackBox: The app's black box; nil when this launch records none.
    ///   - work: The app's blocking-work lanes.
    public func traceMethods(blackBox: TraceBlackBox?, work: any MayBlockRunner) -> [ControlMethod] {
        let parts = TraceControlParts(app: RuntimeTraceRecording(blackBox: blackBox, work: work), daemon: traceLink,
                                      secureInput: SystemSecureInput())
        return TraceControl(parts: parts).methods
    }
}
