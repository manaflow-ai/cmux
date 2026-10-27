import CmuxNextCompat

// The layout motion intervals (`motion.frame`, `motion.run`) with their numbers: like every ``Signposter``
// interval, each is one `OSSignposter` interval (Instruments, `log stream --signpost`), the MetricKit mirror's
// for a mirrored name (``SignpostMetricKitMirror/mirrors(_:)``: `motion.run`) and one trace ring slice while the
// `motion` category is on. Their fields are formatted by the log system only when something reads them, so a
// frame builds no `String`.
extension Signposter {
    /// Begins one window's ``SignpostName/motionFrame``: a display tick to its presentation applied
    /// (`panes=<moved panes> dt_us=<the tick's dt in us>`). The ring's thread slice (B) holds `movedPanes` in
    /// `arg0` and `dtMicros` in `arg1`. End it on this thread with ``end(_:_:)``.
    ///
    /// - Parameters:
    ///   - movedPanes: The panes the frame moves.
    ///   - dtMicros: The tick's dt in microseconds.
    /// - Returns: The state to pass to ``end(_:_:)``.
    public func beginMotionFrame(movedPanes: UInt64, dtMicros: UInt64) -> SignpostInterval {
        openInterval(.motionFrame, arg0: movedPanes, arg1: dtMicros) {
            signposter.beginInterval(SignpostName.motionFrame.staticName, id: $0,
                                     "panes=\(movedPanes, privacy: .public) dt_us=\(dtMicros, privacy: .public)")
        }
    }

    /// Ends a ``SignpostName/motionRun`` begun with ``begin(_:_:)``, with what its frames measured: the log
    /// system's end carries `frames=<frames> longest_us=<longest frame in us>`, the MetricKit mirror ends its
    /// interval, and the ring's AE holds ``motionRunResult(frames:longestFrameMicros:)`` in `arg0`.
    ///
    /// - Parameters:
    ///   - interval: The state ``begin(_:_:)`` returned for ``SignpostName/motionRun``.
    ///   - frames: The CPU frames the run stepped (0 for a motion the render server ran).
    ///   - longestFrameMicros: The longest of them in microseconds.
    public func endMotionRun(_ interval: SignpostInterval, frames: UInt32, longestFrameMicros: UInt32) {
        let name = SignpostName.motionRun
        signposter.endInterval(name.staticName, interval.state,
                               "frames=\(frames, privacy: .public) longest_us=\(longestFrameMicros, privacy: .public)")
        if let id = interval.metricKitID { mirror.end(name, id: id) }
        closeInterval(name, interval, arg0: Self.motionRunResult(frames: frames, longestFrameMicros: longestFrameMicros))
    }

    /// A ``SignpostName/motionRun`` end record's `arg0`: the frames in bits 0-31 and the longest frame in us in
    /// bits 32-63 (an AE's `arg1` is its async id).
    public static func motionRunResult(frames: UInt32, longestFrameMicros: UInt32) -> UInt64 {
        UInt64(frames) | UInt64(longestFrameMicros) << 32
    }
}
