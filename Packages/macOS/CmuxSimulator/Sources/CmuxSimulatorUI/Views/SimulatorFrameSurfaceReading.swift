/// Deep-copies stable worker-published pixels without exposing shared storage.
protocol SimulatorFrameSurfaceReading: AnyObject, Sendable {
    /// Copies the newest stable frame newer than the supplied sequence.
    func copyLatestFrame(after sequence: UInt64?) async -> SimulatorFrameSnapshot?
}
