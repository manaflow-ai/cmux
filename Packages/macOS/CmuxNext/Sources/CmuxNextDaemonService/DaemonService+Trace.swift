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
    /// `work`'s `.files` lane), this daemon and its children, the recording indicator (task 133) and the
    /// secure-input gate. Chromium tracing (task 051) and the typing flows (019) join ``TraceControlParts`` as
    /// they land; until then each reports `unsupported`.
    ///
    /// - Parameters:
    ///   - blackBox: The app's black box; nil when this launch records none.
    ///   - work: The app's blocking-work lanes.
    ///   - indicator: The indicator every window shows while a recording runs.
    public func traceMethods(blackBox: TraceBlackBox?, work: any MayBlockRunner, indicator: (any TraceRecordingIndicator)?) -> [ControlMethod] {
        let parts = TraceControlParts(app: RuntimeTraceRecording(blackBox: blackBox, work: work), daemon: traceLink,
                                      indicator: indicator, secureInput: SystemSecureInput())
        return TraceControl(parts: parts).methods
    }
}
