import AppKit
import OwlMojoBindingsGenerated

@MainActor
final class OwlCursorPresenter {
    private(set) var currentCursor = OwlFreshCursorInfo(type: OwlFreshCursorType.pointer.rawValue)

    func apply(_ cursor: OwlFreshCursorInfo, in host: NSView, suppressBrowserCursor: Bool) {
        guard cursor != currentCursor else {
            return
        }
        currentCursor = cursor
        host.window?.invalidateCursorRects(for: host)
        applyCurrentIfNeeded(in: host, suppressBrowserCursor: suppressBrowserCursor)
    }

    func addCursorRect(in host: NSView, rect: NSRect) {
        host.addCursorRect(rect, cursor: nativeCursor(for: currentCursor))
    }

    func applyCurrentIfNeeded(in host: NSView, suppressBrowserCursor: Bool) {
        guard shouldApplyCurrentCursor(in: host, suppressBrowserCursor: suppressBrowserCursor) else {
            return
        }
        nativeCursor(for: currentCursor).set()
    }

    func nativeCursor(for cursor: OwlFreshCursorInfo) -> NSCursor {
        switch cursor.cursorType {
        case .hand, .contextMenu, .dndLink:
            return .pointingHand
        case .iBeam, .verticalText:
            return .iBeam
        case .cross, .cell:
            return .crosshair
        case .grab:
            return .openHand
        case .grabbing:
            return .closedHand
        case .eastResize, .westResize, .eastWestResize, .columnResize, .eastWestNoResize:
            return .resizeLeftRight
        case .northResize, .southResize, .northSouthResize, .rowResize, .northSouthNoResize:
            return .resizeUpDown
        case .none, .notAllowed, .noDrop, .dndNone:
            return .operationNotAllowed
        default:
            return .arrow
        }
    }

    func nativeCursorName(for cursor: OwlFreshCursorInfo) -> String {
        switch cursor.cursorType {
        case .hand, .contextMenu, .dndLink:
            return "pointingHand"
        case .iBeam, .verticalText:
            return "iBeam"
        case .cross, .cell:
            return "crosshair"
        case .grab:
            return "openHand"
        case .grabbing:
            return "closedHand"
        case .eastResize, .westResize, .eastWestResize, .columnResize, .eastWestNoResize:
            return "resizeLeftRight"
        case .northResize, .southResize, .northSouthResize, .rowResize, .northSouthNoResize:
            return "resizeUpDown"
        case .none, .notAllowed, .noDrop, .dndNone:
            return "operationNotAllowed"
        default:
            return "arrow"
        }
    }

    private func shouldApplyCurrentCursor(in host: NSView, suppressBrowserCursor: Bool) -> Bool {
        guard !suppressBrowserCursor, let window = host.window, window.isKeyWindow else {
            return false
        }
        let location = host.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return host.isMousePoint(location, in: host.bounds)
    }
}
