public import CmuxNextWakeups

extension FrameTick {
    /// The seconds a motion client (a spring, a fade, an autoscroll) steps by in this frame: to the time the frame
    /// shows (``frameElapsed``) with ``MotionTunables/frameOwnerTiming`` on, else ``elapsed``. Read once per frame
    /// and client.
    public var motionElapsed: Double { // perf-hot: 0.5ms frame-tick (every frame)
        MotionTunables.frameOwnerTiming.value ? frameElapsed : elapsed
    }

    /// The time a motion client's step in this frame lands on: the time the frame shows (``targetTimestamp``) with
    /// ``MotionTunables/frameOwnerTiming`` on, else the link time (``timestamp``), as ``motionElapsed`` steps. A
    /// render-server move that starts inside the frame begins there, on the springs' time base (FRAME OWNER S1).
    public var motionTimestamp: CFTimeInterval {
        MotionTunables.frameOwnerTiming.value ? targetTimestamp : timestamp
    }
}
