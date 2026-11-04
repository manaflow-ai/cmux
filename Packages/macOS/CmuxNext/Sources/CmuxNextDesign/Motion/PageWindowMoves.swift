#if DEBUG || CMUX_BENCH_HOOKS
import AppKit

/// Where a window's shown page windows (Chromium's child windows, ``WindowOverlayHost/isPageWindow(_:)``) are at each
/// step of a live-resize `setFrame` (FRAME OWNER REFACTOR S7, DEBUG and bench builds). The fork's tracker
/// (`CmuxParentViewTracker -update`) moves a page window on the parent window's didResize and on a frame notice of the
/// page's host or any ancestor up to the theme frame, all inside the `setFrame`, and on the overlay's page update after
/// it. A step's move tells which of those calls moved the page; the window server's frames just before the turn's commit
/// tell whether that move reached the screen ahead of the content the commit carries.
@MainActor
struct PageWindowMoves {
    /// A step older than this one is another resize's: the next step only notes the frames.
    static let freshness: CFTimeInterval = 0.25

    /// The shown page windows' frames at the last step, by window, and when that step was.
    private var frames: [ObjectIdentifier: CGRect] = [:]
    private var lastStep: CFTimeInterval?

    /// The largest edge change of a shown page window since the last step, in points; nil when no page window shows or
    /// the last step is older than ``freshness``. A page window that appeared since counts nothing. Keeps the frames.
    mutating func step(in window: NSWindow, at time: CFTimeInterval) -> CGFloat? {
        let fresh = lastStep.map { time - $0 <= Self.freshness } ?? false
        var moved: CGFloat?
        var now: [ObjectIdentifier: CGRect] = [:]
        for page in Self.pages(of: window) {
            let id = ObjectIdentifier(page)
            now[id] = page.frame
            guard fresh else { continue }
            moved = max(moved ?? 0, frames[id].map { Self.edgeDistance($0, page.frame) } ?? 0)
        }
        (frames, lastStep) = (now, time)
        return moved
    }

    /// `window`'s shown page windows.
    static func pages(of window: NSWindow) -> [NSWindow] {
        (window.childWindows ?? []).filter { WindowOverlayHost.isPageWindow($0) && $0.isVisible }
    }

    /// The largest distance between the same edges of `a` and `b`.
    static func edgeDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.maxX - b.maxX), abs(a.minY - b.minY), abs(a.maxY - b.maxY))
    }

    /// The window server's frames of `window` and of its shown page windows now, by window number, in the window server's
    /// own space (compared only with each other: a move needs no flip). One window server round trip.
    static func windowServerFrames(of window: NSWindow) -> [Int: CGRect] {
        // The array holds CGWindowID values (not CFNumbers), as `CGWindowListCreateImageFromArray`'s.
        var ids: [UnsafeRawPointer?] = []
        for shown in [window] + pages(of: window) where shown.windowNumber > 0 { ids.append(UnsafeRawPointer(bitPattern: UInt(shown.windowNumber))) }
        guard !ids.isEmpty, let array = CFArrayCreate(nil, &ids, ids.count, nil),
              let listed = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return [:] }
        var frames: [Int: CGRect] = [:]
        for info in listed {
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let rect = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
            else { continue }
            frames[number] = rect
        }
        return frames
    }

    /// AppKit's frames of `window` and of its shown page windows now, by window number.
    static func appKitFrames(of window: NSWindow) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        for shown in [window] + pages(of: window) where shown.windowNumber > 0 { frames[shown.windowNumber] = shown.frame }
        return frames
    }

    /// The largest edge change from `before` to `after` of the windows `numbers` in both; nil when none is in both.
    /// The same in AppKit's space and the window server's (a flip swaps the top and bottom edges, not their changes).
    static func largestMove(from before: [Int: CGRect], to after: [Int: CGRect], of numbers: some Sequence<Int>) -> CGFloat? {
        var moved: CGFloat?
        for number in numbers {
            guard let from = before[number], let to = after[number] else { continue }
            moved = max(moved ?? 0, edgeDistance(from, to))
        }
        return moved
    }
}
#endif
