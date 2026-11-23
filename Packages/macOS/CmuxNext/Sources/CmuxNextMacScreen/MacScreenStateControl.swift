public import CmuxNextControl
import CmuxNextDevices
import Foundation
import CmuxNextSettings

/// `mac_screen.state` (every build; `cmux app mac-screens [--tab TAB]`): one row per Mac Screen
/// tab showing one of the user's devices, read-only, for checking how fast a viewer is:
/// - `tab`, `store_tab` (the tab's id in `cmux tab` commands, when its pane's daemon holds it),
///   `device_id`, `device` (the tab's name for it);
/// - `state`: where the tab is, from the hub's request to the picture (``stateName(hub:session:hasFrame:)``):
///   `idle` (the Connect card), `requesting`, `waiting_for_approval`, `connecting`, `waiting_for_frame`,
///   `viewing`, `failed`, `declined`, `refused`, `revoked`, `ended`; `hub_phase` and `scope` (`view`, `full`)
///   are the hub's own; `error` is the text the tab's card says for a failure, refusal or end (null otherwise);
/// - `phase` (`connecting`, `connected`, `failed`, `ended`; null with no session), `connected`,
///   `has_frame` (a picture is up in this connection), `path` (Direct, Relayed, ...);
/// - `started_by`: who started the view without a person's click (the agent session's title or the
///   calling app, else `agent`), null for a tab a person opened or one waiting at the Connect card;
/// - `waits_to_show` (a scope is held until the tab is shown, so nothing was asked of the hub yet);
/// - `connect_started_at` (ISO 8601, when this session's connect began) and `first_frame_ms`
///   (from it to the first decoded frame reaching the screen; null until then);
/// - `fps`, `target_fps`, `rtt_ms` (latest), `frames_decoded`, `frames_dropped` (frames the other
///   Mac numbered that never showed here), `frame` (the stream's pixel size);
/// - `rtt_ms_window`, `frame_interval_ms` and `present_ms` (decoded to shown): {count, p50, p95,
///   max} over the last 60 round trips and 120 frames; null before the first sample.
/// And `hub` (``hubStateRow``): this Mac's device hub, whether it runs, is registered and shares.
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

    /// `tab` names the tab by its provider key or its store tab id (`cmux tab` commands' id).
    func stateAnswer(_ params: [String: JSONValue]) -> JSONValue {
        let only = params["tab"]?.stringValue
        let rows = tabs.values
            .filter { !$0.record.isHome && (only == nil || $0.key == only || events.storeTabID($0.key) == only) }
            .sorted { $0.key < $1.key }
            .map { tab in
                guard case var .object(row) = Self.stateRow(tab) else { return Self.stateRow(tab) }
                row["store_tab"] = events.storeTabID(tab.key).map(JSONValue.string) ?? .null
                return .object(row)
            }
        return ["tabs": .array(rows), "hub": hubStateRow]
    }

    /// This Mac's device hub as `mac_screen.state` reads it (every build): whether it runs, and
    /// with it this device, whether it shares its screen, the hub link and the user's devices, so
    /// a Release build says why a Mac is not listed or not shareable without DEV tools (CMUX-572).
    /// Ids, names and states only: no key, ticket, token or relay secret.
    var hubStateRow: JSONValue {
        var row: [String: JSONValue] = [
            "configured": .bool(hubConfigured), "running": .bool(hub != nil),
            "startup_error": hubStartupError.map(JSONValue.string) ?? .null,
        ]
        guard let hub else { return .object(row) }
        let me = hub.identity.id
        row["status"] = .string(Self.hubStatusName(hub.status))
        row["connection"] = .string(Self.connectionName(hub.connection))
        row["this_device"] = .string(me)
        row["registered"] = .bool(hub.thisDevice != nil)
        row["sharing"] = .bool(hubHost.isSharing)
        row["served_by_cmux_remote"] = .bool(remoteHosted)
        row["last_error"] = hub.lastError.map { .string($0.description) } ?? .null
        row["devices"] = .array(hub.devices.sorted { $0.name < $1.name }.map { device in
            ["id": .string(device.id), "name": .string(device.name),
             "platform": device.platform.map { .string($0.rawValue) } ?? .null,
             "online": .bool(device.online), "shared": .bool(device.macScreenShared), "this": .bool(device.id == me)]
        })
        return .object(row)
    }

    static func hubStatusName(_ status: DeviceHub.Status) -> String {
        switch status {
        case .idle: "idle"
        case .starting: "starting"
        case .ready: "ready"
        case .failed: "failed"
        }
    }

    static func connectionName(_ state: DeviceHubSocket.State) -> String {
        switch state {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .reconnecting: "reconnecting"
        case .replaced: "replaced"
        case .removed: "removed"
        case .signedOut: "signed_out"
        }
    }

    static func stateRow(_ tab: MacScreenTab) -> JSONValue {
        var row: [String: JSONValue] = [
            "tab": .string(tab.key),
            "device_id": tab.record.deviceID.map(JSONValue.string) ?? .null,
            "device": .string(tab.title),
            "phase": .null, "connected": false, "has_frame": false,
            "connect_started_at": .null, "first_frame_ms": .null,
            "state": .string("not_started"), "hub_phase": .null, "scope": .null, "error": .null,
        ]
        guard let pane = tab.pane else { return .object(row) }
        row["has_frame"] = .bool(pane.model.hasFrame)
        row["started_by"] = pane.model.startedBy.map { .string($0.stateValue) } ?? .null
        let hubPhase = pane.model.hub?.phase
        row["state"] = .string(stateName(hub: hubPhase, session: pane.session?.phase, hasFrame: pane.model.hasFrame))
        row["hub_phase"] = hubPhase.map { .string(hubPhaseName($0)) } ?? .null
        row["scope"] = hubPhase.flatMap(Self.scope).map { .string($0.rawValue) } ?? .null
        row["error"] = errorText(pane.model).map(JSONValue.string) ?? .null
        // Waiting for Connect to show: the hub holds a scope to resume.
        row["waits_to_show"] = .bool(pane.model.hub?.resumeScope != nil)
        guard let session = pane.session else { return .object(row) }
        // A session that never connected sits in its initial `.ended`: no stream, not one that ended.
        let started = session.timings.startedAt != nil || session.phase != .ended
        row["phase"] = started ? .string(phaseName(session.phase)) : .null
        row["connected"] = .bool(session.phase == .connected)
        // Where a connect is (no_answer, no_link, no_frame, shown), and where one that timed out stopped.
        row["connect_stage"] = .string(session.connectStage.name)
        row["timed_out_at"] = session.timedOutStage.map { .string($0.name) } ?? .null
        row["path"] = .string(session.streamPath)
        let timings = session.timings
        row["connect_started_at"] = timings.startedAt.map { .string($0.formatted(.iso8601)) } ?? .null
        row["first_frame_ms"] = timings.firstFrameMs.map(JSONValue.number) ?? .null
        // Connect start to the end of each stage passed (answer, link, frame), on a connected read too.
        row["connect_stage_ms"] = .object(Dictionary(uniqueKeysWithValues: timings.stageMs.map { ($0.key.timingKey, JSONValue.number($0.value)) }))
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
        // The viewer's stages to the glass (design D8): Decode, Present and the two together.
        row["decode_ms"] = frames.map { summary($0.decode) } ?? .null
        row["glass_ms"] = frames.map { summary($0.glass) } ?? .null
        row["decode_present_ms"] = frames.map { summary($0.decodePresent) } ?? .null
        return .object(row)
    }

    private static func summary(_ samples: MacScreenRollingSamples) -> JSONValue {
        guard let summary = samples.summary else { return .null }
        func ms(_ value: Double) -> JSONValue { .number((value * 10).rounded() / 10) }
        return ["count": .number(Double(summary.count)), "p50": ms(summary.p50), "p95": ms(summary.p95), "max": ms(summary.max)]
    }

    /// The tab's one state: the hub's phase until its stream runs, then the session's, and `viewing`
    /// only once a picture is up (`waiting_for_frame` while connected without one).
    static func stateName(hub: MacScreenHubPhase?, session: MacScreenSession.Phase?, hasFrame: Bool) -> String {
        switch hub {
        case .idle?: return "idle"
        case .requesting?: return "requesting"
        case .waitingForApproval?: return "waiting_for_approval"
        case .approved?: return "connecting"
        case .streamFailed?: return "failed"
        case .declined?: return "declined"
        case .refused?: return "refused"
        case .revoked?: return "revoked"
        case .ended?: return "ended"
        case .streaming?, nil: break
        }
        switch session {
        case .connecting?: return "connecting"
        case .connected?: return hasFrame ? "viewing" : "waiting_for_frame"
        case .failed?: return "failed"
        case .ended?: return "ended"
        case nil: return "not_started"
        }
    }

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

    private static func scope(_ phase: MacScreenHubPhase) -> SessionScope? {
        switch phase {
        case let .requesting(scope), let .waitingForApproval(_, scope), let .approved(_, scope), let .streaming(_, scope),
             let .streamFailed(_, scope), let .declined(scope), let .refused(_, scope): scope
        case .idle, .revoked, .ended: nil
        }
    }

    /// What the tab's card says went wrong (a failure, refusal, decline, revocation or end), as the
    /// person reads it; nil while it connects, streams or waits for Connect, and for the person's own
    /// Disconnect. The card's words only: never the session's free-form message (it can quote the signaling URL).
    static func errorText(_ model: MacScreenPaneModel) -> String? {
        let name = model.name
        let text: String
        switch model.card {
        case .failed?:
            text = model.failedDetail
        case let .hubRefused(refusal, _)?:
            let title = MacScreenCardView.refusedTitle(refusal, host: name)
            let body = MacScreenCardView.refusedBody(refusal, host: name, platform: model.platform)
            text = title + ": " + body
        case .hubDeclined?:
            text = String(format: L.t("macScreen.hub.declinedBody", "%@ declined your request."), name)
        case let .hubRevoked(reason)?, let .hubEnded(reason)?:
            guard reason != .viewerDisconnected else { return nil }
            let detail = MacScreenCardView.failedDetail(model.card, model)
            text = detail.isEmpty ? reason.text(host: name) : detail
        case .hubAccessLowered?:
            text = String(format: L.t("macScreen.hub.loweredBody", "%@ now lets this Mac view its screen but not control it."), name)
        default:
            return nil
        }
        return text.isEmpty ? nil : text
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
