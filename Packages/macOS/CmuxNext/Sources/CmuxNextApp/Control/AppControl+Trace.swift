import Carbon.HIToolbox
import CmuxNextControl
import CmuxNextFeatures

extension AppControl {
    /// `trace.start`, `trace.stop` and `trace.status` (p09-observability task 020) while the `traceControl`
    /// feature is on, else none. Their parts: the app's ring (its black box maps the recording ring on the
    /// `.files` lane), the daemon's trace commands, which reach its children, and the secure-input gate.
    /// Chromium tracing (task 051), the typing flows (019) and the indicator (133) join ``TraceControlParts``
    /// as they land; until then each reports `unsupported`.
    static func traceMethods(_ services: AppServices) -> [ControlMethod] {
        guard services.features.isEnabled(.traceControl) else { return [] }
        let daemon = services.daemon
        let parts = TraceControlParts(
            app: RuntimeTraceRecording(blackBox: services.traceBlackBox?.blackBox, work: services.work),
            daemon: DaemonTraceLink { [weak daemon] in await MainActor.run { daemon?.connection } },
            secureInput: SystemSecureInput())
        return TraceControl(parts: parts).methods
    }
}

/// Secure keyboard entry as the window server reports it: any app's password field, or a terminal's secure
/// input (TerminalSecureInput), so no per-key trace record is written while one is on.
private struct SystemSecureInput: TraceSecureInput {
    var isSecureInputActive: Bool { IsSecureEventInputEnabled() }
}
