public import CmuxNextWakeups

extension FrameTick {
    /// The seconds a motion client (a spring, a fade, an autoscroll) steps by in this frame: to the time the frame
    /// shows (``frameElapsed``) with ``MotionTunables/frameOwnerTiming`` on, else ``elapsed``. Read once per frame
    /// and client.
    public var motionElapsed: Double { // perf-hot: 0.5ms frame-tick (every frame)
        MotionTunables.frameOwnerTiming.value ? frameElapsed : elapsed
    }
}
