import CCmuxLayoutReducerFFI
public import CoreGraphics

/// The visibility of an agent cursor target (a browser tab). The rules live
/// in Rust (cmux-focus-core `agent_cursor_visibility`, shared vectors
/// schemas/agent-cursor-visibility). This calls them through the typed C ABI
/// `cmux_agent_cursor_visibility`, once per agent input event and per frame of
/// pane motion while a target is tracked: ids numbered for the call, flat
/// arrays, a struct answer, no JSON and no allocation on the Rust side.
public nonisolated struct AgentCursorVisibilityResolver {
    public nonisolated init() {}

    public static func resolve(target: String, in snapshot: AgentCursorVisibilitySnapshot) -> AgentCursorVisibility {
        let flat = AgentCursorVisibilityFlatSnapshot(target: target, snapshot: snapshot)
        var out = CmuxCursorVisibility()
        let code = flat.withSnapshot { cmux_agent_cursor_visibility($0, &out) }
        let answer = code == CMUX_LAYOUT_REDUCER_OK ? flat.visibility(out) : nil
        assert(answer != nil, "cmux_agent_cursor_visibility refused (\(code))")
        // A refused call draws nothing.
        return answer ?? .notDrawn(.tabClosed)
    }
}
