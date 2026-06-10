import AppKit
import Bonsplit
import SwiftUI


// MARK: - Window drag and move suppression
private enum WindowDragHandleAssociatedObjectKeys {
    private static let suppressionDepthToken = NSObject()
    private static let moveSuppressionSequenceToken = NSObject()

    static let suppressionDepth = UnsafeRawPointer(Unmanaged.passUnretained(suppressionDepthToken).toOpaque())
    static let moveSuppressionSequence = UnsafeRawPointer(Unmanaged.passUnretained(moveSuppressionSequenceToken).toOpaque())
}

// Stored as an NSWindow associated object and touched only from AppKit's
// main-thread mouse-event dispatch path.
private final class WindowMoveSuppressionSequenceState: @unchecked Sendable {
    let reason: WindowMoveSuppressionReason
    let previousMovableState: Bool

    init(reason: WindowMoveSuppressionReason, previousMovableState: Bool) {
        self.reason = reason
        self.previousMovableState = previousMovableState
    }
}

func beginWindowDragSuppression(window: NSWindow?) -> Int? {
    guard let window else { return nil }
    let current = windowDragSuppressionDepth(window: window)
    let next = current + 1
    objc_setAssociatedObject(
        window,
        WindowDragHandleAssociatedObjectKeys.suppressionDepth,
        NSNumber(value: next),
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    return next
}

@discardableResult
func endWindowDragSuppression(window: NSWindow?) -> Int {
    guard let window else { return 0 }
    let current = windowDragSuppressionDepth(window: window)
    let next = max(0, current - 1)
    if next == 0 {
        objc_setAssociatedObject(
            window,
            WindowDragHandleAssociatedObjectKeys.suppressionDepth,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    } else {
        objc_setAssociatedObject(
            window,
            WindowDragHandleAssociatedObjectKeys.suppressionDepth,
            NSNumber(value: next),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
    return next
}

func windowDragSuppressionDepth(window: NSWindow?) -> Int {
    guard let window,
          let value = objc_getAssociatedObject(window, WindowDragHandleAssociatedObjectKeys.suppressionDepth) as? NSNumber else {
        return 0
    }
    return value.intValue
}

func isWindowDragSuppressed(window: NSWindow?) -> Bool {
    windowDragSuppressionDepth(window: window) > 0
}

func activeWindowMoveSuppressionSequenceReason(window: NSWindow?) -> WindowMoveSuppressionReason? {
    guard let window,
          let state = objc_getAssociatedObject(
            window,
            WindowDragHandleAssociatedObjectKeys.moveSuppressionSequence
          ) as? WindowMoveSuppressionSequenceState else {
        return nil
    }
    return state.reason
}

@discardableResult
func beginWindowMoveSuppressionSequence(
    window: NSWindow?,
    reason: WindowMoveSuppressionReason
) -> WindowMoveSuppressionReason? {
    guard let window else { return nil }
    if let activeReason = activeWindowMoveSuppressionSequenceReason(window: window) {
        ensureWindowMoveSuppressionSequenceIsImmovable(window: window)
        return activeReason
    }

    let previousMovableState = window.isMovable
    _ = beginWindowDragSuppression(window: window)
    if window.isMovable {
        window.isMovable = false
    }
    let state = WindowMoveSuppressionSequenceState(
        reason: reason,
        previousMovableState: previousMovableState
    )
    objc_setAssociatedObject(
        window,
        WindowDragHandleAssociatedObjectKeys.moveSuppressionSequence,
        state,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    return reason
}

func ensureWindowMoveSuppressionSequenceIsImmovable(window: NSWindow?) {
    guard let window,
          activeWindowMoveSuppressionSequenceReason(window: window) != nil,
          window.isMovable else {
        return
    }
    window.isMovable = false
}

@discardableResult
func finishWindowMoveSuppressionSequence(window: NSWindow?) -> WindowMoveSuppressionReason? {
    guard let window,
          let state = objc_getAssociatedObject(
            window,
            WindowDragHandleAssociatedObjectKeys.moveSuppressionSequence
          ) as? WindowMoveSuppressionSequenceState else {
        return nil
    }

    objc_setAssociatedObject(
        window,
        WindowDragHandleAssociatedObjectKeys.moveSuppressionSequence,
        nil,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    _ = endWindowDragSuppression(window: window)
    restoreWindowDragging(window: window, previousMovableState: state.previousMovableState)
    return state.reason
}

func restoreWindowDragging(window: NSWindow?, previousMovableState: Bool?) {
    guard let window,
          let previousMovableState else { return }
    if window.isMovable != previousMovableState {
        window.isMovable = previousMovableState
    }
}

@discardableResult
func clearWindowDragSuppression(window: NSWindow?) -> Int {
    guard let window else { return 0 }
    if activeWindowMoveSuppressionSequenceReason(window: window) != nil {
        _ = finishWindowMoveSuppressionSequence(window: window)
    }
    var depth = windowDragSuppressionDepth(window: window)
    while depth > 0 {
        depth = endWindowDragSuppression(window: window)
    }
    return depth
}

/// Temporarily enables window movability for explicit drag-handle drags, then
/// restores the previous movability state after `body` finishes.
@discardableResult
func withTemporaryWindowMovableEnabled(window: NSWindow?, _ body: () -> Void) -> Bool? {
    guard let window else {
        body()
        return nil
    }

    let previousMovableState = window.isMovable
    if !previousMovableState {
        window.isMovable = true
    }
    defer {
        if window.isMovable != previousMovableState {
            window.isMovable = previousMovableState
        }
    }

    body()
    return previousMovableState
}

