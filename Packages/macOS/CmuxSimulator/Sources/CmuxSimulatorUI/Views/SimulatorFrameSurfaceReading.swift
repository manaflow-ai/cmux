/// Deep-copies stable worker-published pixels without exposing shared storage.
protocol SimulatorFrameSurfaceReading: AnyObject, Sendable {
    /// Returns whether a publication newer than `sequence` is available without copying pixels.
    func hasPublishedFrame(after sequence: UInt64?) -> Bool
    /// Copies the newest stable frame newer than the supplied sequence.
    func copyLatestFrame(after sequence: UInt64?) async -> SimulatorFrameSnapshot?
    /// Installs or removes a process-safe frame-publication callback.
    ///
    /// Returns `true` when publications will wake the callback. Sources that
    /// cannot signal return `false`, allowing the view to retain bounded
    /// display-cadence polling as a compatibility fallback.
    @discardableResult
    func setFramePublicationHandler(
        _ handler: (@Sendable () -> Void)?
    ) -> Bool
}

extension SimulatorFrameSurfaceReading {
    func hasPublishedFrame(after sequence: UInt64?) -> Bool { true }

    @discardableResult
    func setFramePublicationHandler(
        _ handler: (@Sendable () -> Void)?
    ) -> Bool { false }
}
