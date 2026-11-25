import CCmuxLayoutReducerFFI
public import CoreGraphics

/// The visibility of an agent cursor target (a browser tab). The rules live
/// in Rust (cmux-focus-core `agent_cursor_visibility`, shared vectors
/// schemas/agent-cursor-visibility). This calls them through the typed C ABI
/// `cmux_agent_cursor_visibility`, once per agent input event and per frame of
/// pane motion while a target is tracked: ids numbered for the call, flat
/// arrays, a struct answer, no JSON and no allocation on the Rust side. A kept
/// resolver reuses its arrays, so its per-frame resolves allocate no new storage.
public nonisolated struct AgentCursorVisibilityResolver {
    /// The call's flat arrays, refilled by each resolve.
    private var flat = AgentCursorVisibilityFlatSnapshot()

    public nonisolated init() {}

    /// A one-off resolve (the debug socket): its arrays are new for the call.
    public static func resolve(target: String, in snapshot: AgentCursorVisibilitySnapshot) -> AgentCursorVisibility {
        var resolver = Self()
        return resolver.resolve(target: target, in: snapshot)
    }

    /// Resolves with this resolver's arrays, kept from its last resolve.
    public mutating func resolve(target: String, in snapshot: AgentCursorVisibilitySnapshot) -> AgentCursorVisibility {
        flat.load(target: target, snapshot: snapshot)
        var out = CmuxCursorVisibility()
        let code = flat.withSnapshot { cmux_agent_cursor_visibility($0, &out) }
        let answer = code == CMUX_LAYOUT_REDUCER_OK ? flat.visibility(out) : nil
        assert(answer != nil, "cmux_agent_cursor_visibility refused (\(code))")
        // A refused call draws nothing.
        return answer ?? .notDrawn(.tabClosed)
    }
}
