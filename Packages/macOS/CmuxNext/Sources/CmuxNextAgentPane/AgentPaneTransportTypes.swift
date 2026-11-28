public import Foundation

/// Why the host's socket refused a page frame or stopped. The raw value is the code the page
/// receives (a bridge failure, or `closed.error` of a transport event).
public nonisolated enum AgentPaneTransportError: String, Error, Equatable, Sendable {
    /// `transport.open` without a handshake that named a daemon (or its connection was used).
    case noConnection = "transport.no_connection"
    case connectFailed = "transport.connect_failed"
    /// A send or close for a connection that is not the current one.
    case staleConnection = "transport.stale_connection"
    case closed = "transport.closed"
    case invalidFrame = "transport.invalid_frame"
    case frameTooLarge = "transport.frame_too_large"
    case firstFrameNotInitialize = "transport.first_frame"
    /// The method is not on ``AcpmuxPaneMethods``.
    case methodRefused = "transport.method_refused"
    /// `transport.gesture` params break the intent contract (``AgentPaneGestureIntent``), a
    /// redeeming frame carries other `_meta` (R1), or a method other than set_mode and
    /// set_config_option names a mode field (P1).
    case intentInvalid = "transport.intent_invalid"
    /// A mode, or a config option that is not free, which the daemon does not say keeps the
    /// session asking, without the user's confirmation (R2, P2).
    case modeNotConfirmed = "transport.mode_not_confirmed"
    /// `_acpmux/harness_enable` without the user's Enable on the native sheet: Cancel, no sheet
    /// to show, another confirmation open, or no prompt from acpmux to show.
    case harnessNotConfirmed = "transport.harness_not_confirmed"
    /// A page request whose id (JSON value and type) is still waiting for its reply.
    case requestIdInFlight = "transport.request_id_in_flight"
    /// One object of the frame holds two keys that decode to the same string (ad349, round 7).
    case duplicateKey = "transport.duplicate_key"
    /// The frame grants (allows a permission, trusts a folder, prompts, sets a mode) without a
    /// fresh user gesture; the socket stays open.
    case gestureRequired = "transport.gesture_required"
    /// The frame carries `mcpServers` entries ({command, args, env}): the page may not make the
    /// harness spawn a command (C1).
    case mcpServersRefused = "transport.mcp_servers_refused"
    /// A `cwd` or `path` param that is not an absolute existing path (a `cwd` must be a directory).
    case pathInvalid = "transport.path_invalid"
    /// A `cwd` or `path` param outside the pane's workspace roots (``AcpmuxPathPolicy``).
    case pathOutsideRoots = "transport.path_outside_roots"
    /// A kill or permission answer for a session this pane did not start and does not show.
    case sessionNotInPane = "transport.session_not_in_pane"
    /// The page did not take frames as fast as the daemon sent them; the socket was closed.
    case inboundOverflow = "transport.inbound_overflow"
    /// The daemon did not take the page's frames; the socket was closed.
    case outboundOverflow = "transport.outbound_overflow"
}

/// How the socket ended: the close code and reason, and the host's error when the host closed it.
public nonisolated struct AgentPaneTransportClose: Equatable, Sendable {
    public var code: Int
    public var reason: String
    public var error: AgentPaneTransportError?
}

/// One push to the page: frames in arrival order, then (at most once) the close.
public nonisolated struct AgentPaneTransportEvent: Equatable, Sendable {
    public var connection: Int
    public var frames: [String]
    public var closed: AgentPaneTransportClose?

    var object: [String: Any] {
        var object: [String: Any] = ["connection": connection]
        if !frames.isEmpty { object["frames"] = frames }
        if let closed {
            var close: [String: Any] = ["code": closed.code, "reason": closed.reason]
            if let error = closed.error { close["error"] = error.rawValue }
            object["closed"] = close
        }
        return object
    }

    /// The old host's push: `cmuxAcpmuxTransport.receive(event)` (bridgeSocket.ts).
    var script: String {
        let json = (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "window.cmuxAcpmuxTransport?.receive(\(json));"
    }
}
