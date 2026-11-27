/// `ui.calm` in cmux.json: "off" (default), "calm" or "still" (``CalmMode``).
/// It overrides the motion and hover-card settings while on and leaves them
/// as they are, so turning it off restores them.
public nonisolated struct CalmModeSetting {
    public nonisolated init() {}
    // The path and default are generated from schemas/settings/source/motion.json.
}
