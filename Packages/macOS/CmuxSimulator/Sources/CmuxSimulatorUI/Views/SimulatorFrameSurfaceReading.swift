/// Deep-copies stable worker-published pixels without exposing shared storage.
protocol SimulatorFrameSurfaceReading: AnyObject, Sendable {
    /// Returns whether a publication newer than `sequence` is available without copying pixels.
    func hasPublishedFrame(after sequence: UInt64?) -> Bool
    /// Copies the newest stable frame newer than the supplied sequence.
    func copyLatestFrame(after sequence: UInt64?) async -> SimulatorFrameSnapshot?
}

extension SimulatorFrameSurfaceReading {
    func hasPublishedFrame(after sequence: UInt64?) -> Bool { true }
}
