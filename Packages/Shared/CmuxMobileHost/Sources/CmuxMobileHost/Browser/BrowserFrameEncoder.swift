/// Encodes captured frames (VideoToolbox H.264 on the Mac).
public protocol BrowserFrameEncoder: Sendable {
    /// Encodes one frame; the encoder reconfigures itself when the frame size
    /// or bitrate changed (a size change always yields a keyframe).
    func encode(_ frame: BrowserCapturedFrame, bitrate: Int, maxFPS: Int, forceKeyframe: Bool) async throws -> BrowserEncodedFrame?
    /// Releases the encoder (the hardware session).
    func close() async
}
