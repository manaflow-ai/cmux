import CMUXMobileCore
import Foundation

/// Decides which requests stranded on a replaced control stream may be sent
/// again on its replacement.
///
/// A request written to the old stream may have reached the host and been
/// applied, with only the answer lost. Sending it again is safe only when a
/// second application has no effect, so this is an allowlist of read-only
/// methods. Every other method, including any method added later, is failed
/// back to its caller as a timeout (outcome unknown) instead.
enum MobileRPCControlFrameResendPolicy {
    /// Read-only probe the session sends to verify a replacement stream.
    static let verificationProbeMethod = "mobile.events.probe"

    /// Methods whose host handlers only read state.
    ///
    /// Deliberately excluded although they look like reads:
    /// `mobile.terminal.viewport` and viewport-reporting replays (they resize
    /// the terminal, and a stale resend could undo a newer size),
    /// `mobile.events.subscribe`/`unsubscribe` (subscription state),
    /// `*.artifact.fetch` (registers a transfer on the host),
    /// `mobile.terminal.artifact.scan`, and `mobile.surface.focus`.
    static let readOnlyMethods: Set<String> = [
        "caffeine.status",
        "mobile.browser.list",
        "mobile.chat.history",
        "mobile.chat.sessions",
        "mobile.directory.list",
        "mobile.directory.search",
        "mobile.events.probe",
        "mobile.host.status",
        "mobile.panel.artifact.stat",
        "mobile.rpc.methods",
        "mobile.simulator.devices.list",
        "mobile.simulator.list",
        "mobile.sync.fetch",
        "mobile.task.models.list",
        "mobile.terminal.artifact.list",
        "mobile.terminal.artifact.stat",
        "mobile.workspace.changes.file_diff",
        "mobile.workspace.changes.file_stat",
        "mobile.workspace.changes.files",
        "mobile.workspace.changes.summary",
        "mobile.workspace.list",
        "notification.feed.list",
        "phone_push.status.get",
        "workspace.list",
    ]

    /// Replay parameters that turn a replay into a viewport report, which the
    /// host applies as a resize before capturing the replay.
    static let replayViewportReportParameters: Set<String> = [
        "client_id",
        "viewport_columns",
        "viewport_rows",
    ]

    /// Whether one encoded `MobileSyncFrameCodec` request frame is safe to
    /// send again after a stream replacement.
    static func allowsResend(ofFrame frame: Data) -> Bool {
        let headerByteCount = MobileSyncFrameCodec.headerByteCount
        guard frame.count > headerByteCount else { return false }
        return allowsResend(ofPayload: Data(frame.dropFirst(headerByteCount)))
    }

    static func allowsResend(ofPayload payload: Data) -> Bool {
        guard let request = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let method = request["method"] as? String else {
            return false
        }
        if readOnlyMethods.contains(method) { return true }
        guard method == "mobile.terminal.replay" || method == "terminal.replay" else {
            return false
        }
        let params = request["params"] as? [String: Any] ?? [:]
        return replayViewportReportParameters.isDisjoint(with: params.keys)
    }
}
