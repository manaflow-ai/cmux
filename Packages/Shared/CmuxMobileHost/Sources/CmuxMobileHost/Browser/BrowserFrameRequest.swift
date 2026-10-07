/// What the handler asks of the video source for the next frame.
public struct BrowserFrameRequest: Hashable, Sendable {
    /// Encode size in pixels (even).
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Target bitrate in bits per second.
    public var bitrate: Int
    public var maxFPS: Int

    public init(pixelWidth: Int, pixelHeight: Int, bitrate: Int, maxFPS: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bitrate = bitrate
        self.maxFPS = maxFPS
    }
}
