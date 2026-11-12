#if os(iOS)
import CoreGraphics
import QuartzCore

/// Per-session scroll smoothness, in the terms Apple uses for hitches.
///
/// A frame hitches when it reaches the display after the deadline the previous
/// frame promised (`CADisplayLink.targetTimestamp`); the lateness is its hitch
/// time. A row shift is a visible row whose position in the table's content
/// changed during the session: rigid scrolling moves the content offset, never
/// the rows, so any shift is a layout change under the user's finger.
struct WorkspaceListScrollSmoothnessTally: Equatable {
    /// Lateness below this is display-timing noise, not a missed frame.
    static let hitchTolerance: CFTimeInterval = 0.001

    private(set) var frames = 0
    private(set) var hitchedFrames = 0
    private(set) var hitchedFramesWithListWork = 0
    private(set) var hitchSeconds: CFTimeInterval = 0
    private(set) var worstHitchSeconds: CFTimeInterval = 0
    private(set) var rowShifts = 0
    private var promisedTimestamp: CFTimeInterval?
    private var rowOrigins: [String: CGFloat] = [:]
    private var firstTimestamp: CFTimeInterval?
    private var lastTimestamp: CFTimeInterval?

    var durationSeconds: CFTimeInterval {
        guard let firstTimestamp, let lastTimestamp else { return 0 }
        return max(0, lastTimestamp - firstTimestamp)
    }

    /// Milliseconds of hitch per second of scrolling.
    var hitchRatio: Double {
        durationSeconds > 0 ? hitchSeconds * 1000 / durationSeconds : 0
    }

    /// Records one displayed frame. `listWorked` says whether the table did
    /// reconcile or cell work since the previous frame.
    mutating func recordFrame(
        timestamp: CFTimeInterval,
        targetTimestamp: CFTimeInterval,
        listWorked: Bool
    ) {
        if firstTimestamp == nil { firstTimestamp = timestamp }
        lastTimestamp = timestamp
        frames += 1
        if let promisedTimestamp {
            let lateness = timestamp - promisedTimestamp
            if lateness > Self.hitchTolerance {
                hitchedFrames += 1
                hitchSeconds += lateness
                worstHitchSeconds = max(worstHitchSeconds, lateness)
                if listWorked { hitchedFramesWithListWork += 1 }
            }
        }
        promisedTimestamp = targetTimestamp
    }

    /// Records where each visible row sits in content coordinates, returning
    /// the rows that moved since they were last seen this session.
    mutating func recordRows(_ origins: [String: CGFloat]) -> [(id: String, delta: CGFloat)] {
        var moved: [(id: String, delta: CGFloat)] = []
        for (id, origin) in origins {
            if let previous = rowOrigins[id], abs(origin - previous) > 0.5 {
                moved.append((id, origin - previous))
            }
            rowOrigins[id] = origin
        }
        rowShifts += moved.count
        return moved
    }
}
#endif
