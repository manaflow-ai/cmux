/// Reads this Mac's screen for the Chief. ``ChiefScreenSystemCapture`` is the real one; tests pass a fake.
public protocol ChiefScreenCapturing: Sendable {
    /// Whether Screen Recording is allowed for this app now. A TCC query: runs off the caller's actor.
    @concurrent
    func isAllowed() async -> Bool

    /// Asks macOS for Screen Recording (its prompt, the first time only).
    ///
    /// - Returns: Whether it is allowed now.
    @concurrent
    func requestAccess() async -> Bool

    /// Looks at the screen once.
    ///
    /// - Parameter previous: The last frame's signature; nil always answers a frame.
    /// - Returns: The frame, or nil when it looks the same as `previous`.
    /// - Throws: When the screen cannot be captured (Screen Recording was taken back).
    @concurrent
    func capture(changedSince previous: VoiceRoomFrameSignature?) async throws -> ChiefScreenFrame?
}
