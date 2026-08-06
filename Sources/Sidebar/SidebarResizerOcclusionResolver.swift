import AppKit
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

/// Non-observed pointer-button state fed by the app's existing local event
/// monitor. Cursor release reads this state without synchronously querying
/// WindowServer from the main actor.
@MainActor
final class SidebarResizerPointerButtonState {
    private(set) var isLeftButtonDown = false

    func observe(_ eventType: NSEvent.EventType) {
        switch eventType {
        case .leftMouseDown:
            isLeftButtonDown = true
        case .leftMouseUp:
            isLeftButtonDown = false
        default:
            break
        }
    }

    func reset() {
        isLeftButtonDown = false
    }
}

@MainActor
struct SidebarResizerOcclusionResolver {
    var topmostMouseEventWindowNumber: (NSPoint) -> Int? = { screenPoint in
        let windowNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        return windowNumber > 0 ? windowNumber : nil
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
        guard isInDividerBand else { return false }
        return topmostMouseEventWindowNumber(screenPoint) == observedWindowNumber
    }
}
