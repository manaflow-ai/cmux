import Foundation

/// The frame intervals of one pan of a terminal (the finger's drag and its fling), as the
/// phone sends them to its Mac's `phone-frames` service (PROTOCOL.md "Services",
/// `phone-frames-v1`). The Mac's host turns them into p50/p95/max frame time and hitches and
/// logs one line per pan (`phone_frames.rs`), so an agent on the Mac reads how the shipped
/// app scrolled. The math lives there; this is the wire shape.
public struct TerminalPanFrames: Encodable, Equatable, Sendable {
    public enum Kind: String, Encodable, Sendable {
        /// A full-screen app on the alternate screen, scrolled by wheel reports.
        case tui
        /// The terminal page itself (scrollback).
        case scrollback
    }

    /// Most intervals one pan records (15 s at 120 Hz); the recorder stops there.
    public static let maxFrames = 1800
    /// Fewest intervals worth a line (a tap that moved a point is not a scroll).
    public static let minFrames = 4

    public var v = 1
    public var kind: Kind
    /// The program the terminal runs (`claude`, `zsh`); the session fills it in.
    public var program: String?
    /// The app's version and build (`1.2 (345)`).
    public var app: String?
    /// The display's nominal frame interval (ms), the shortest the pan saw.
    public var expectedMs: Double
    /// Each interval between consecutive frames (ms, 0.01 ms steps).
    public var intervalsMs: [Double]

    public init(kind: Kind, program: String? = nil, app: String? = TerminalPanFrames.appVersion, expectedMs: Double, intervalsMs: [Double]) {
        self.kind = kind
        self.program = program
        self.app = app
        self.expectedMs = Self.rounded(expectedMs)
        self.intervalsMs = intervalsMs.prefix(Self.maxFrames).map(Self.rounded)
    }

    enum CodingKeys: String, CodingKey {
        case v, kind, program, app
        case expectedMs = "expected_ms"
        case intervalsMs = "intervals_ms"
    }

    /// The JSON line for `phone-frames`, or nil when the pan is too short or has no display rate.
    public func line() -> Data? {
        guard intervalsMs.count >= Self.minFrames, expectedMs > 0 else { return nil }
        return try? JSONEncoder().encode(self)
    }

    static func rounded(_ ms: Double) -> Double { (ms * 100).rounded() / 100 }

    /// `CFBundleShortVersionString (CFBundleVersion)` of the running app.
    public static let appVersion: String? = {
        guard let info = Bundle.main.infoDictionary, let version = info["CFBundleShortVersionString"] as? String else { return nil }
        return "\(version) (\(info["CFBundleVersion"] as? String ?? "?"))"
    }()
}

/// Counts one pan's frames from display-link ticks, in constant time per frame: one append
/// into storage reserved for ``TerminalPanFrames/maxFrames`` intervals, kept across pans.
public struct TerminalPanFrameTally: Sendable {
    public private(set) var intervalsMs: [Double] = []
    private var last: Double?
    private var nominalMs = Double.infinity

    public init() { intervalsMs.reserveCapacity(TerminalPanFrames.maxFrames) }

    public var isFull: Bool { intervalsMs.count >= TerminalPanFrames.maxFrames }

    /// One tick at `timestamp` (s) whose display frame is `nominal` (s). Returns whether the
    /// pan is full and the recorder should stop.
    public mutating func tick(timestamp: Double, nominal: Double) -> Bool {
        if let last, timestamp > last, !isFull { intervalsMs.append((timestamp - last) * 1000) }
        last = timestamp
        if nominal > 0 { nominalMs = min(nominalMs, nominal * 1000) }
        return isFull
    }

    /// The pan so far, and a tally ready for the next one (its storage kept).
    public mutating func take(_ kind: TerminalPanFrames.Kind) -> TerminalPanFrames {
        let pan = TerminalPanFrames(kind: kind, expectedMs: nominalMs.isFinite ? nominalMs : 0, intervalsMs: intervalsMs)
        intervalsMs.removeAll(keepingCapacity: true)
        last = nil
        nominalMs = .infinity
        return pan
    }
}
