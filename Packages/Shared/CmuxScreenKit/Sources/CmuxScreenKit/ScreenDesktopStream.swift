import CmuxVNC
import CoreGraphics
import QuartzCore

/// A screen stream an app runs on its own transport and decoder: the iPhone's cmux.rd/1
/// viewer of a Linux desktop, whose link and viewer core are Rust. ``ScreenSession`` drives
/// it like its other streams (connect, reconnect, input, stats); the stream draws its
/// pictures into ``layer`` and says what happens through the `events` handler.
@MainActor
public protocol ScreenDesktopStream: AnyObject, Sendable {
    /// Where the decoded pictures show (an `AVSampleBufferDisplayLayer`).
    var layer: CALayer { get }
    /// Connects; `events` hears the stream on the main actor until it ends or is closed.
    func start(_ events: @escaping @MainActor (ScreenDesktopEvent) -> Void)
    /// One input event (nothing on a view-only stream).
    func send(_ input: ScreenDesktopInput)
    /// The picture is broken or stale: asks the host for a keyframe.
    func requestKeyframe()
    /// The stream's counters now (the stats line samples them once a second).
    func sample() -> ScreenDesktopSample
    /// Ends the stream; no event follows.
    func close()
}

public enum ScreenDesktopEvent: Sendable, Equatable {
    /// The host serves the stream (its `welcome`), at this size in stream pixels.
    case connected(width: Int, height: Int)
    /// A picture showed at a new size (the first, or the host changed it).
    case picture(CGSize)
    /// The link's path: through a relay, or direct.
    case path(relayed: Bool)
    /// The stream ended (the host, the link, the signaling), with the reason for the logs.
    case ended(String)
}

/// One input event in stream pixels and X11 terms; the stream's transport turns keysyms
/// and typed text into the host's keys.
public enum ScreenDesktopInput: Sendable, Equatable {
    case pointer(x: Int, y: Int)
    /// X numbering: 1 left, 2 middle, 3 right.
    case button(Int, down: Bool)
    /// Hundredths of a wheel line; negative `dy` scrolls up, negative `dx` left.
    case scroll(dx: Int, dy: Int)
    case keysym(VNCKeysym, down: Bool)
    /// Typed text (the software keyboard, dictation, a paste).
    case type(String)
}

/// A desktop stream's counters since it started.
public struct ScreenDesktopSample: Sendable, Equatable {
    public var framesReceived: UInt64
    public var framesShown: UInt64
    public var framesLost: UInt64
    public var bytes: UInt64
    public var roundTripMs: Double?
    public var decodeMs: Double?
    /// The codec and decoder for the stats line ("H264 HW").
    public var encoding: String

    public init(framesReceived: UInt64 = 0, framesShown: UInt64 = 0, framesLost: UInt64 = 0, bytes: UInt64 = 0,
                roundTripMs: Double? = nil, decodeMs: Double? = nil, encoding: String = "-") {
        self.framesReceived = framesReceived
        self.framesShown = framesShown
        self.framesLost = framesLost
        self.bytes = bytes
        self.roundTripMs = roundTripMs
        self.decodeMs = decodeMs
        self.encoding = encoding
    }
}
