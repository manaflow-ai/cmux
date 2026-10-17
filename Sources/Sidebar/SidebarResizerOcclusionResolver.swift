import AppKit
import CmuxBrowser
import CmuxFoundation

@MainActor
final class SidebarResizerCursorReleaseScheduler {
    private let scheduler: MainActorDeferredActionScheduler

    init(clock: any Clock<Duration> = ContinuousClock()) {
        scheduler = MainActorDeferredActionScheduler(clock: clock)
    }

    func cancelPendingRelease() {
        scheduler.cancel()
    }

    func schedule(
        force: Bool,
        delay: Duration,
        release: @escaping @MainActor (Bool) -> Void
    ) {
        scheduler.schedule(after: delay, zeroDelayPolicy: .yieldOnce) {
            release(force)
        }
    }
}

@MainActor
struct SidebarResizerOcclusionResolver {
    var topmostMouseEventWindowNumber: (NSPoint) -> Int? = { screenPoint in
        let windowNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        return windowNumber > 0 ? windowNumber : nil
    }
    /// The window a window acts for: a Chromium page's child window acts for
    /// the cmux window it sits in (its pages lie over the band's content side),
    /// any other window for itself.
    var actingWindowNumber: (Int) -> Int = { windowNumber in
        guard let window = NSApp.window(withWindowNumber: windowNumber),
              let acting = window.chromiumActingWindow(fallback: nil) else { return windowNumber }
        return acting.windowNumber
    }

    func dividerBandContains(
        point: NSPoint,
        contentBounds: NSRect,
        isLeftSidebarVisible: Bool,
        leftDividerX: CGFloat,
        isRightSidebarVisible: Bool,
        rightDividerX: CGFloat
    ) -> Bool {
        guard point.y >= contentBounds.minY, point.y <= contentBounds.maxY else { return false }
        if isLeftSidebarVisible,
           SidebarResizeInteraction.Edge.leading.hitRange(dividerX: leftDividerX).contains(point.x) {
            return true
        }
        return isRightSidebarVisible &&
            SidebarResizeInteraction.Edge.trailing.hitRange(dividerX: rightDividerX).contains(point.x)
    }

    func bandMayActivate(
        isDragging: Bool,
        isInDividerBand: Bool,
        screenPoint: NSPoint,
        observedWindowNumber: Int
    ) -> Bool {
        guard !isDragging else { return true }
        guard isInDividerBand,
              let topmost = topmostMouseEventWindowNumber(screenPoint) else { return false }
        return topmost == observedWindowNumber || actingWindowNumber(topmost) == observedWindowNumber
    }
}
