/// Reads this Mac's screen for the Chief. ``ChiefScreenHelperCapture`` is the real one (through the cmux
/// Computer Use helper, which holds Screen Recording); tests pass a fake.
public protocol ChiefScreenCapturing: Sendable {
    /// Whether Screen Recording is allowed for the process that captures. A TCC query in that process.
    ///
    /// - Throws: ``ChiefScreenCaptureInterruption/unavailable`` when that process is not running.
    @concurrent
    func isAllowed() async throws -> Bool

    /// Asks macOS for Screen Recording for the process that captures (its prompt, the first time only).
    ///
    /// - Returns: Whether it is allowed now.
    /// - Throws: ``ChiefScreenCaptureInterruption/unavailable`` when that process is not running.
    @concurrent
    func requestAccess() async throws -> Bool

    /// Looks at the screen once.
    ///
    /// - Parameter previous: The last frame's signature; nil always answers a frame.
    /// - Returns: The frame, or nil when it looks the same as `previous`.
    /// - Throws: ``ChiefScreenCaptureInterruption`` when the capture process is restarting or lost Screen
    ///   Recording; any other error when the screen cannot be read.
    @concurrent
    func capture(changedSince previous: VoiceRoomFrameSignature?) async throws -> ChiefScreenFrame?
}
