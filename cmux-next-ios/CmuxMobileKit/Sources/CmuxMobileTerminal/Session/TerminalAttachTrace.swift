import Foundation

/// Where a terminal page's attach spends its time, up to the first frame that
/// shows the Mac's program at its final grid (Leo, 2026-11-17, softened: "the
/// loading of everything needs to be FASTER"). The page marks each step of
/// its attach (the view loaded, the Ghostty surface made, the first grid
/// measured and sent, the session started, the Mac's grid, reset and replay,
/// the replay parsed, each resize after it) and each display frame that turns
/// right or wrong; ``firstRightMs`` is the start of the last right run, the
/// first frame after which nothing changed the grid again.
///
/// The terminal demo's `attach` phase reports it (TerminalAttachFirstFrameUITests).
public struct TerminalAttachTrace: Equatable, Sendable {
    public struct Mark: Equatable, Sendable {
        public var name: String
        /// Milliseconds since the page's view loaded.
        public var ms: Int
    }

    /// The most marks kept (a flood of resizes stops recording, never grows).
    public static let capacity = 96

    public let origin: TimeInterval
    public private(set) var marks: [Mark] = []
    /// When the last run of right frames began (nil: the last frame was wrong).
    public private(set) var rightSince: TimeInterval?
    /// The trace's first `start` mark (the session was started), if any.
    public private(set) var startedAt: TimeInterval?
    private var once: Set<String> = []

    public init(origin: TimeInterval) { self.origin = origin }

    public mutating func mark(_ name: String, at now: TimeInterval) {
        guard marks.count < Self.capacity else { return }
        if name == "start", startedAt == nil { startedAt = now }
        marks.append(Mark(name: name, ms: Int(((now - origin) * 1000).rounded())))
    }

    /// Marks `name` only the first time it is seen.
    public mutating func markOnce(_ name: String, at now: TimeInterval) {
        guard once.insert(name).inserted else { return }
        mark(name, at: now)
    }

    /// One display frame: `right` when it shows the program at its final grid
    /// with nothing held, replayed, queued or still to be answered.
    public mutating func frame(right: Bool, at now: TimeInterval) {
        if right, rightSince == nil {
            rightSince = now
            mark("right", at: now)
        } else if !right, rightSince != nil {
            rightSince = nil
            mark("wrong", at: now)
        }
    }

    /// Milliseconds from the view loading to the first frame of the last right run.
    public var firstRightMs: Int? {
        rightSince.map { Int((($0 - origin) * 1000).rounded()) }
    }

    /// Milliseconds from the session's start to the first frame of the last right run.
    public var firstRightFromStartMs: Int? {
        guard let rightSince, let startedAt else { return nil }
        return Int(((rightSince - startedAt) * 1000).rounded())
    }

    /// `name@ms` for each mark, comma separated (no spaces: one label word).
    public var line: String {
        marks.map { "\($0.name)@\($0.ms)" }.joined(separator: ",")
    }
}
