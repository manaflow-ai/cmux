#if DEBUG
#if canImport(UIKit)
extension GhosttySurfaceView {
    /// Test hook: surface behavior tests run in a scene-less xctest host where
    /// a Metal present can never complete, so a real render dispatch stalls,
    /// trips the render-pipeline stall recovery, and resets the surface under
    /// test. True skips the render dispatch entirely; terminal state
    /// (`process_output`, binding actions, `read_text`) never needs a present.
    /// Static so the seam lives in this debug-only file instead of the
    /// production class body; tests set it once per suite on the main actor.
    static var debugSkipRenderDispatchForTesting = false
}
#endif
#endif
