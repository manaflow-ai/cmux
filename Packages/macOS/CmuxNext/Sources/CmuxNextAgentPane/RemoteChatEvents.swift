public import CmuxNextSettings
public import Foundation

/// What a chat on another machine shows, as app events on `events.stream` (`cmux events`), so a
/// probe reads the app's own word for it instead of walking the window's accessibility tree
/// (cmuxterm-hq remote_reconnect_probe.py: 63 reds in a row were a walk cut at 25 levels, not a
/// missing row). Two events, each with `at_ms`, this Mac's wall clock in ms since the epoch:
///
/// - `agent.peer.link` `{peer, state, at_ms}`: the app's acpmux pushed a peer's link state
///   (`_acpmux/peer_state_changed`: `connected` only after the handshake; `connecting`, `degraded`,
///   `reconnecting`, `restarting`, `offline`...). The composer's machine-link row draws this push
///   (peerLink.ts), so its states and their times are the row's.
/// - `agent.chat.live_paint` `{session, peer, link, at_ms}`: a chat of `peer` drew acpmux's settled
///   view of itself (the page's `pane.painted` with `settled`, once per chat it opens): the live
///   session is on screen. `link` is the peer's last state pushed before it.
///
/// Nothing is drawn or changed for the person; a chat on this Mac publishes nothing. O(1) each.
/// The App owns one (``AgentPaneMachineLink/events``) and points `publish` at the control socket's bus.
public final class RemoteChatEvents {
    public static let linkEvent = "agent.peer.link"
    public static let livePaintEvent = "agent.chat.live_paint"

    /// Publishes one event (`name`, `payload`) on the control socket's bus, once it is up.
    public var publish: (_ name: String, _ payload: [String: JSONValue]) -> Void = { _, _ in }
    /// The acpmux peer a session runs on (its lane's `peer`), nil for a chat on this Mac.
    public var peerOf: (String) -> String? = { _ in nil }
    public var now: () -> Date = { Date() }

    /// Each peer's last pushed state, for the paint's `link`. Peers are few (enrolled machines).
    public private(set) var links: [String: String] = [:]

    public init() {}

    public func linkChanged(peer: String?, state: String?) {
        guard let peer, !peer.isEmpty, let state, !state.isEmpty else { return }
        links[peer] = state
        publish(Self.linkEvent, ["peer": .string(peer), "state": .string(state), "at_ms": atMilliseconds])
    }

    public func livePainted(session: String?) {
        guard let session, let peer = peerOf(session), !peer.isEmpty else { return }
        publish(Self.livePaintEvent, [
            "session": .string(session), "peer": .string(peer),
            "link": links[peer].map(JSONValue.string) ?? .null, "at_ms": atMilliseconds,
        ])
    }

    private var atMilliseconds: JSONValue { .number((now().timeIntervalSince1970 * 1000).rounded()) }
}
