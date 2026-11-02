public import CoreGraphics
import CmuxNextFocus

/// The visibility of an agent cursor target (a browser tab). The rules live
/// in Rust (cmux-focus-core `agent_cursor_visibility`, shared vectors
/// schemas/agent-cursor-visibility); this sends the App's snapshot over the
/// app FFI's JSON channel, once per agent input event or tracked change.
public nonisolated struct AgentCursorVisibilityResolver {
    public nonisolated init() {}

    public static func resolve(target: String, in snapshot: AgentCursorVisibilitySnapshot) -> AgentCursorVisibility {
        let answer = FocusReducer.call("agent_cursor_visibility", Request(target: target, snapshot: snapshot), as: Answer.self)
        assert(answer?.visibility != nil, "agent_cursor_visibility refused")
        // A refused call (a snapshot that does not encode) draws nothing.
        return answer?.visibility ?? .notDrawn(.tabClosed)
    }

    private nonisolated struct Request: Encodable {
        var target: String
        var snapshot: AgentCursorVisibilitySnapshot
    }

    /// `{"kind":"visible","window","viewport","clip","zoom","scale"}`,
    /// `{"kind":"hidden","window","anchor","rect"}` or `{"kind":"notDrawn","reason"}`.
    private nonisolated struct Answer: Decodable {
        var kind: String
        var window: String?
        var viewport: AgentCursorRect?
        var clip: AgentCursorRect?
        var zoom: Double?
        var scale: Double?
        var anchor: String?
        var rect: AgentCursorRect?
        var reason: AgentCursorNotDrawnReason?

        var visibility: AgentCursorVisibility? {
            switch kind {
            case "visible":
                guard let window, let viewport, let clip, let zoom else { return nil }
                return .visible(window: window, viewport: viewport.cgRect, clip: clip.cgRect, zoom: zoom, scale: scale ?? 1)
            case "hidden":
                guard let window, let anchor = anchor.flatMap(AgentCursorAnchor.init(wireName:)), let rect else { return nil }
                return .hidden(window: window, anchor: anchor, rect: rect.cgRect)
            case "notDrawn":
                return reason.map { .notDrawn($0) }
            default:
                return nil
            }
        }
    }
}
