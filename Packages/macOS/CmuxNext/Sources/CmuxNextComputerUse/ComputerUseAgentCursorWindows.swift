// The person's pointer as metadata beside the agent's (normalized to the window, `visible: false`
// outside it, clamped to its edge, never drawn into the captured pixels) is ported from Petal's
// telepointers (kiruna-labs/petal @ 7ac436a, apps/desktop/src-tauri/src/telepointer.rs, Apache-2.0).
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

/// The person's own pointer over a window: a fraction of the window (0...1 from the top left,
/// clamped to its edge) and whether it is inside it. Metadata only: the stream never has a cursor.
public nonisolated struct ComputerUsePersonPointer: Equatable, Sendable {
    public var point: CGPoint
    public var visible: Bool

    public init(point: CGPoint, visible: Bool) {
        self.point = point
        self.visible = visible
    }
}

/// Both pointers over a streamed window, read together on one tick.
public nonisolated struct ComputerUseWindowPointers: Equatable, Sendable {
    /// The helper's agent cursor; nil when none shows in the window.
    public var agent: ComputerUseAgentCursor?
    /// The person's pointer; nil when the window or the pointer could not be read.
    public var person: ComputerUsePersonPointer?

    public init(agent: ComputerUseAgentCursor? = nil, person: ComputerUsePersonPointer? = nil) {
        self.agent = agent
        self.person = person
    }
}

/// Where the helper's agent cursor and the person's pointer are in a window
/// (``ComputerUseLiveCapture``); tests pass a fake.
public nonisolated protocol ComputerUseAgentCursorReading: Sendable {
    /// The agent cursor of helper `helper` in `window`; nil when none of its cursors shows in it.
    @concurrent func cursor(in window: ComputerUsePreviewWindow, helper: pid_t) async -> ComputerUseAgentCursor?
    /// The agent cursor (helper `helper`; nil: none runs) and the person's pointer in `window`.
    @concurrent func pointers(in window: ComputerUsePreviewWindow, helper: pid_t?) async -> ComputerUseWindowPointers
}

extension ComputerUseAgentCursorReading {
    /// A reader that knows only the agent's cursor: no person pointer.
    @concurrent public func pointers(in window: ComputerUsePreviewWindow, helper: pid_t?) async -> ComputerUseWindowPointers {
        guard let helper else { return ComputerUseWindowPointers() }
        return ComputerUseWindowPointers(agent: await cursor(in: window, helper: helper))
    }
}

/// ``ComputerUseAgentCursorReading`` from the WindowServer's window list. The legacy helper draws
/// each session's agent cursor in a small square window of its own, centered on the cursor's tip
/// (144 points; seen 2026-10-28: a cursor moved to (400, 300) put its window at (328, 228)). A
/// window's bounds need no Screen Recording grant. The live stream captures the target window
/// alone, so the card draws the cursor itself (B6). The agent's accessibility clicks report no
/// click point: this is the one place their position shows. The person's pointer comes from the
/// same read: `CGEvent(source: nil)`'s location is in the window list's coordinates (global, top
/// left origin), so no screen flip is needed and no permission is asked.
public nonisolated struct ComputerUseAgentCursorWindows: ComputerUseAgentCursorReading {
    /// The cursor windows' sides the helper uses: a square in this range (144 points today).
    static let sides: ClosedRange<CGFloat> = 32...320

    public init() {}

    @concurrent public func cursor(in window: ComputerUsePreviewWindow, helper: pid_t) async -> ComputerUseAgentCursor? {
        read(window, helper: helper, person: false).agent
    }

    @concurrent public func pointers(in window: ComputerUsePreviewWindow, helper: pid_t?) async -> ComputerUseWindowPointers {
        read(window, helper: helper, person: true)
    }

    /// One window list read: the target's bounds, the helper's cursor tips in it and, when asked,
    /// the person's pointer over it.
    private func read(_ window: ComputerUsePreviewWindow, helper: pid_t?, person: Bool) -> ComputerUseWindowPointers {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return ComputerUseWindowPointers()
        }
        var target: CGRect?
        var tips: [CGPoint] = []
        for info in list {
            guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { continue }
            if (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window.windowID {
                target = bounds
            } else if let helper, (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == helper,
                      bounds.width == bounds.height, Self.sides.contains(bounds.width) {
                tips.append(CGPoint(x: bounds.midX, y: bounds.midY))
            }
        }
        guard let target else { return ComputerUseWindowPointers() }
        let agent = Self.fraction(tips, in: target).map { ComputerUseAgentCursor(point: $0, windowWidth: target.width) }
        let location = person ? CGEvent(source: nil)?.location : nil
        return ComputerUseWindowPointers(agent: agent, person: location.flatMap { Self.person($0, in: target) })
    }

    /// The person's pointer at `location` (global, top left origin) as a fraction of `window`:
    /// visible inside it; outside, clamped to the nearest edge and not visible, so a page that drew
    /// the last visible point never draws one off the window.
    static func person(_ location: CGPoint, in window: CGRect) -> ComputerUsePersonPointer? {
        guard window.width > 0, window.height > 0 else { return nil }
        let x = (location.x - window.minX) / window.width
        let y = (location.y - window.minY) / window.height
        let inside = (0...1).contains(x) && (0...1).contains(y)
        return ComputerUsePersonPointer(point: CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)), visible: inside)
    }

    /// The first tip inside `window`, as a fraction of it.
    static func fraction(_ tips: [CGPoint], in window: CGRect?) -> CGPoint? {
        guard let window, window.width > 0, window.height > 0, let tip = tips.first(where: { window.contains($0) }) else {
            return nil
        }
        return CGPoint(x: (tip.x - window.minX) / window.width, y: (tip.y - window.minY) / window.height)
    }
}
