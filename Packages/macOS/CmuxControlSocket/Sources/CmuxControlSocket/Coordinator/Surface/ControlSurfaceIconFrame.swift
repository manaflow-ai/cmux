/// One untrusted SVG frame transported by the surface-icon protocol.
///
/// The coordinator bounds its UTF-8 size and duration, but does not validate SVG
/// syntax or safety. The app must validate and render it off the main actor.
public struct ControlSurfaceIconFrame: Sendable, Equatable {
    /// The raw SVG source, limited by the wire parser to 16 KiB of UTF-8.
    public let svg: String

    /// The frame duration in milliseconds, from 50 through 5,000 inclusive.
    public let durationMS: Int

    /// Creates a raw frame without rendering or validating SVG syntax.
    ///
    /// - Parameters:
    ///   - svg: The untrusted SVG source.
    ///   - durationMS: The requested frame duration in milliseconds.
    public init(svg: String, durationMS: Int) {
        self.svg = svg
        self.durationMS = durationMS
    }
}
