#if DEBUG
extension SessionDisplaySnapshot {
    /// A compact one-line description of the captured display for session
    /// save/restore debug logs, e.g. `id=1 frame={...} visible={...}`. Nested
    /// rects render via `SessionRectSnapshot.debugLogDescription`; absent fields
    /// render as `nil`, matching the legacy app-target formatter.
    public var debugLogDescription: String {
        let displayIdText = displayID.map(String.init) ?? "nil"
        return "id=\(displayIdText) " +
            "frame={\(frame?.debugLogDescription ?? "nil")} " +
            "visible={\(visibleFrame?.debugLogDescription ?? "nil")}"
    }
}
#endif
