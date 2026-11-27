import CmuxSwiftRender

/// A full description of what the render worker should show: which sidebar
/// file, the live data context to interpret it against, and the host's
/// scroll-inset chrome.
///
/// Sent host → worker whenever the data context (or the selected file) changes.
/// The worker owns reading and watching the file itself; the host never parses
/// or renders the file's contents — that is the whole point of remote
/// rendering.
public struct RenderScene: Codable, Sendable, Equatable {
    /// Monotonic sequence number the worker echoes back in
    /// ``RenderWorkerOutbound/ack(_:)`` once the scene is applied, driving the
    /// client's hang watchdog.
    public var seq: UInt64
    /// Absolute path of the `.swift` or `.json` sidebar file to render.
    public var filePath: String
    /// Live, read-only values the interpreter binds identifiers to.
    public var state: [String: SwiftValue]
    /// Top scroll inset so content rests below the host titlebar accessory.
    public var topInset: Double
    /// Bottom scroll inset so content fades into the host's footer band.
    public var bottomInset: Double

    /// Creates a scene update.
    ///
    /// - Parameters:
    ///   - seq: Monotonic sequence number echoed back in the worker's ack.
    ///   - filePath: Absolute path of the sidebar file to render.
    ///   - state: Live data context the interpreter binds identifiers to.
    ///   - topInset: Top scroll inset reserved for host chrome.
    ///   - bottomInset: Bottom scroll inset reserved for host chrome.
    public init(
        seq: UInt64,
        filePath: String,
        state: [String: SwiftValue],
        topInset: Double,
        bottomInset: Double
    ) {
        self.seq = seq
        self.filePath = filePath
        self.state = state
        self.topInset = topInset
        self.bottomInset = bottomInset
    }
}
