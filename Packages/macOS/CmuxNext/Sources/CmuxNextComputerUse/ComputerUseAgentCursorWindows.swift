import CoreGraphics
public import Foundation

/// The helper's agent cursor in a window: its tip as a fraction of the window (0...1 from the top
/// left), and the window's width in points (the card draws the cursor at the window's scale).
public nonisolated struct ComputerUseAgentCursor: Equatable, Sendable {
    public var point: CGPoint
    public var windowWidth: Double

    public init(point: CGPoint, windowWidth: Double) {
        self.point = point
        self.windowWidth = windowWidth
    }
}

/// Where the helper's agent cursor is in a window (``ComputerUseLiveCapture``); tests pass a fake.
public nonisolated protocol ComputerUseAgentCursorReading: Sendable {
    /// The agent cursor of helper `helper` in `window`; nil when none of its cursors shows in it.
    @concurrent func cursor(in window: ComputerUsePreviewWindow, helper: pid_t) async -> ComputerUseAgentCursor?
}

/// ``ComputerUseAgentCursorReading`` from the WindowServer's window list. The legacy helper draws
/// each session's agent cursor in a small square window of its own, centered on the cursor's tip
/// (144 points; seen 2026-10-28: a cursor moved to (400, 300) put its window at (328, 228)). A
/// window's bounds need no Screen Recording grant. The live stream captures the target window
/// alone, so the card draws the cursor itself (B6). The agent's accessibility clicks report no
/// click point: this is the one place their position shows.
public nonisolated struct ComputerUseAgentCursorWindows: ComputerUseAgentCursorReading {
    /// The cursor windows' sides the helper uses: a square in this range (144 points today).
    static let sides: ClosedRange<CGFloat> = 32...320

    public init() {}

    @concurrent public func cursor(in window: ComputerUsePreviewWindow, helper: pid_t) async -> ComputerUseAgentCursor? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var target: CGRect?
        var tips: [CGPoint] = []
        for info in list {
            guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { continue }
            if (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window.windowID {
                target = bounds
            } else if (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == helper,
                      bounds.width == bounds.height, Self.sides.contains(bounds.width) {
                tips.append(CGPoint(x: bounds.midX, y: bounds.midY))
            }
        }
        guard let target, let point = Self.fraction(tips, in: target) else { return nil }
        return ComputerUseAgentCursor(point: point, windowWidth: target.width)
    }

    /// The first tip inside `window`, as a fraction of it.
    static func fraction(_ tips: [CGPoint], in window: CGRect?) -> CGPoint? {
        guard let window, window.width > 0, window.height > 0, let tip = tips.first(where: { window.contains($0) }) else {
            return nil
        }
        return CGPoint(x: (tip.x - window.minX) / window.width, y: (tip.y - window.minY) / window.height)
    }
}
