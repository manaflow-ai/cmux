import AppKit
import Bonsplit
import SwiftUI

/// A transparent view that enables dragging the window when clicking in empty titlebar space.
/// This lets us keep `window.isMovableByWindowBackground = false` so drags in the app content
/// (e.g. sidebar tab reordering) don't move the whole window.
struct WindowDragHandleView: NSViewRepresentable {
    static let viewIdentifier = NSUserInterfaceItemIdentifier("cmux.titlebarDragHandle")

    var doubleClickBehavior: TitlebarDoubleClickBehavior = .standardAction

    func makeNSView(context: Context) -> NSView {
        DraggableView(doubleClickBehavior: doubleClickBehavior)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? DraggableView)?.doubleClickBehavior = doubleClickBehavior
    }

    private final class DraggableView: NSView {
        var doubleClickBehavior: TitlebarDoubleClickBehavior

        init(doubleClickBehavior: TitlebarDoubleClickBehavior) {
            self.doubleClickBehavior = doubleClickBehavior
            super.init(frame: .zero)
            identifier = WindowDragHandleView.viewIdentifier
        }

        required init?(coder: NSCoder) {
            self.doubleClickBehavior = .standardAction
            super.init(coder: coder)
            identifier = WindowDragHandleView.viewIdentifier
        }

        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let currentEvent = NSApp.currentEvent
            // Fast bail-out: only claim hits for left-mouse-down events.
            // For mouseMoved / mouseEntered / etc., return nil immediately
            // to avoid re-entering SwiftUI view state during layout passes,
            // which causes exclusive-access crashes.
            guard currentEvent?.type == .leftMouseDown else {
                return nil
            }
            let shouldCapture = windowDragHandleShouldCaptureHit(
                point,
                in: self,
                eventType: currentEvent?.type,
                eventWindow: currentEvent?.window
            )
            #if DEBUG
            cmuxDebugLog(
                "titlebar.dragHandle.hitTestResult capture=\(shouldCapture) point=\(windowDragHandleFormatPoint(point)) window=\(window != nil)"
            )
            #endif
            return shouldCapture ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            #if DEBUG
            let point = convert(event.locationInWindow, from: nil)
            let depth = windowDragSuppressionDepth(window: window)
            cmuxDebugLog(
                "titlebar.dragHandle.mouseDown point=\(windowDragHandleFormatPoint(point)) clickCount=\(event.clickCount) depth=\(depth)"
            )
            #endif

            if event.clickCount >= 2 {
                let result = handleTitlebarDoubleClick(
                    window: window,
                    behavior: doubleClickBehavior
                )
                #if DEBUG
                cmuxDebugLog("titlebar.dragHandle.mouseDownDoubleClick result=\(String(describing: result))")
                #endif
                if result.consumesEvent {
                    return
                }
            }

            guard !isWindowDragSuppressed(window: window) else {
                #if DEBUG
                cmuxDebugLog("titlebar.dragHandle.mouseDownIgnored reason=suppressed")
                #endif
                return
            }

            if let window {
                let previousMovableState = withTemporaryWindowMovableEnabled(window: window) {
                    window.performDrag(with: event)
                }
                #if DEBUG
                let restored = previousMovableState.map { String($0) } ?? "nil"
                cmuxDebugLog("titlebar.dragHandle.mouseDownComplete restoredMovable=\(restored) nowMovable=\(window.isMovable)")
                #endif
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

