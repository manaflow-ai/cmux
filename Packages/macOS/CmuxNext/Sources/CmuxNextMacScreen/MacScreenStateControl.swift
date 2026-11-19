public import CmuxNextControl
import Foundation
import CmuxNextSettings

/// `mac_screen.state` (every build; `cmux app mac-screens [--tab TAB]`): one row per Mac Screen
/// tab showing one of the user's devices, read-only, for checking how fast a viewer is:
/// - `tab`, `device_id`, `device` (the tab's name for it);
/// - `phase` (`connecting`, `connected`, `failed`, `ended`; null with no session), `connected`,
///   `has_frame` (a picture is up in this connection), `path` (Direct, Relayed, ...);
/// - `connect_started_at` (ISO 8601, when this session's connect began) and `first_frame_ms`
///   (from it to the first decoded frame reaching the screen; null until then);
/// - `fps`, `target_fps`, `rtt_ms` (latest), `frames_decoded`, `frames_dropped` (frames the other
///   Mac numbered that never showed here), `frame` (the stream's pixel size);
/// - `rtt_ms_window`, `frame_interval_ms` and `present_ms` (decoded to shown): {count, p50, p95,
///   max} over the last 60 round trips and 120 frames; null before the first sample;
/// - `hub_phase` (`idle` is the Connect card, then `requesting`, `waiting_for_approval`, `approved`,
///   `streaming`, or `stream_failed`, `declined`, `refused`, `revoked`, `ended`) and `hub_reason`;
/// - `luma_mean` and `luma_variance` (0-255 luma over a 32 x 32 grid of the latest measured frame,
///   ``MacScreenFrameProbe``): a real picture varies (hundreds or more), a black or flat grey one
///   is near 0; null before the first frame. An end-to-end check reads these, never a window screenshot.
/// No credential, no device address, no pixel of the screen. Nothing here connects, disconnects or
/// sends input: those stay the person's clicks in the pane (and `debug.mac_screen` in DEV builds).
extension MacScreenPages {
    /// The methods every build registers. The CLI's `app mac-screens` reads the first
    /// (`MAC_SCREENS_METHOD` in cmux-tui's cli/app.rs; a test holds the two equal).
    nonisolated public static let releaseMethods = ["mac_screen.state"]

    /// Registers ``releaseMethods`` (every build) and `debug.mac_screen` (DEV builds;
    /// ``registerDebug(on:openTab:)`` says what `openTab` does).
    public func registerControl(on router: ControlRouter?, openTab: @escaping @MainActor (MacScreenRecord, String?) -> String?) {
        registerState(on: router)
        registerDebug(on: router, openTab: openTab)
    }

    /// Registers ``releaseMethods`` (Release and DEV builds alike).
    public func registerState(on router: ControlRouter?) {
        router?.register([
            .async(Self.releaseMethods[0]) { [weak self] call in
                guard let self else { return .null }
                return await stateAnswer(call.params)
            },
        ])
    }

    func stateAnswer(_ params: [String: JSONValue]) -> JSONValue {
        let only = params["tab"]?.stringValue
        let rows = tabs.values
            .filter { !$0.record.isHome && (only == nil || $0.key == only) }
            .sorted { $0.key < $1.key }
            .map(Self.stateRow)
        return ["tabs": .array(rows)]
    }

    static func stateRow(_ tab: MacScreenTab) -> JSONValue {
        var row: [String: JSONValue] = [
            "tab": .string(tab.key),
            "device_id": tab.record.deviceID.map(JSONValue.string) ?? .null,
            "device": .string(tab.title),
            "phase": .null, "connected": false, "has_frame": false,
            "connect_started_at": .null, "first_frame_ms": .null,
        ]
        guard let pane = tab.pane else { return .object(row) }
        row["has_frame"] = .bool(pane.model.hasFrame)
        if let hub = pane.model.hub {
            row["hub_phase"] = .string(hubPhaseName(hub.phase))
            row["hub_reason"] = hubReason(hub.phase).map(JSONValue.string) ?? .null
        }
        guard let session = pane.session else { return .object(row) }
        row["phase"] = .string(phaseName(session.phase))
        row["connected"] = .bool(session.phase == .connected)
        row["path"] = .string(session.streamPath)
        let timings = session.timings
        row["connect_started_at"] = timings.startedAt.map { .string($0.formatted(.iso8601)) } ?? .null
        row["first_frame_ms"] = timings.firstFrameMs.map(JSONValue.number) ?? .null
        let stats = session.stats
        row["fps"] = .number((stats.fps * 10).rounded() / 10)
        row["target_fps"] = stats.targetFps.map { .number(Double($0)) } ?? .null
        row["rtt_ms"] = stats.latencyMs.map(JSONValue.number) ?? .null
        row["frames_decoded"] = .number(stats.framesDecoded)
        row["frames_dropped"] = .number(stats.framesDropped)
        row["frame"] = .string("\(Int(session.frameSize.width))x\(Int(session.frameSize.height))")
        row["rtt_ms_window"] = summary(timings.rtt)
        let frames = session.frameCounter?.timings
        row["frame_interval_ms"] = frames.map { summary($0.intervals) } ?? .null
        row["present_ms"] = frames.map { summary($0.present) } ?? .null
        let probe = session.frameCounter?.latestProbe
        row["luma_mean"] = probe.map { .number(($0.mean * 10).rounded() / 10) } ?? .null
        row["luma_variance"] = probe.map { .number(($0.variance * 10).rounded() / 10) } ?? .null
        return .object(row)
    }

    private static func summary(_ samples: MacScreenRollingSamples) -> JSONValue {
        guard let summary = samples.summary else { return .null }
        func ms(_ value: Double) -> JSONValue { .number((value * 10).rounded() / 10) }
        return ["count": .number(Double(summary.count)), "p50": ms(summary.p50), "p95": ms(summary.p95), "max": ms(summary.max)]
    }

    /// The device hub's side of the tab: how far the request got before (and around) the stream.
    static func hubPhaseName(_ phase: MacScreenHubPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .requesting: "requesting"
        case .waitingForApproval: "waiting_for_approval"
        case .approved: "approved"
        case .streaming: "streaming"
        case .streamFailed: "stream_failed"
        case .declined: "declined"
        case .refused: "refused"
        case .revoked: "revoked"
        case .ended: "ended"
        }
    }

    /// The hub's reason a session ended or was revoked, when it gave one.
    static func hubReason(_ phase: MacScreenHubPhase) -> String? {
        switch phase {
        case let .revoked(reason), let .ended(reason): reason
        default: nil
        }
    }

    static func phaseName(_ phase: MacScreenSession.Phase) -> String {
        switch phase {
        case .connecting: "connecting"
        case .connected: "connected"
        case .failed: "failed"
        case .ended: "ended"
        }
    }
}
