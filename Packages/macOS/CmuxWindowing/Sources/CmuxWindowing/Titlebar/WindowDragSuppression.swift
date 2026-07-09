public import AppKit
import ObjectiveC.runtime

/// Per-window state for an active window-move suppression sequence.
///
/// Stored as an NSWindow associated object and touched only from AppKit's
/// main-thread mouse-event dispatch path. Faithful lift of the app-target
/// `WindowMoveSuppressionSequenceState`.
private final class WindowMoveSuppressionSequenceState: @unchecked Sendable {
    let reason: WindowMoveSuppressionReason
    let previousMovableState: Bool

    init(reason: WindowMoveSuppressionReason, previousMovableState: Bool) {
        self.reason = reason
        self.previousMovableState = previousMovableState
    }
}

/// Window-move/drag suppression. The app keeps a window immovable for the
/// duration of a folder/pane-tab drag (and any nested drag-handle suppression),
/// then restores the window's prior movability. State is kept as NSWindow
/// associated objects so it survives across the AppKit event-dispatch calls that
/// open and close a sequence. Faithful lift of the app-target free functions
/// (`beginWindowDragSuppression`/`endWindowDragSuppression`/sequence helpers);
/// optionality now lives at the call site.
extension NSWindow {
    // Associated-object key tokens. Stable identities reused as opaque pointers
    // for `objc_{set,get}AssociatedObject`.
    private static let dragSuppressionDepthToken = NSObject()
    private static let moveSuppressionSequenceToken = NSObject()
    private static let dragSuppressionDepthKey =
        UnsafeRawPointer(Unmanaged.passUnretained(dragSuppressionDepthToken).toOpaque())
    private static let moveSuppressionSequenceKey =
        UnsafeRawPointer(Unmanaged.passUnretained(moveSuppressionSequenceToken).toOpaque())

    /// The current drag-suppression nesting depth for this window (0 when none).
    @MainActor
    public var windowDragSuppressionDepth: Int {
        guard let value = objc_getAssociatedObject(self, NSWindow.dragSuppressionDepthKey) as? NSNumber else {
            return 0
        }
        return value.intValue
    }

    /// Whether window dragging is currently suppressed for this window.
    @MainActor
    public var isWindowDragSuppressed: Bool {
        windowDragSuppressionDepth > 0
    }

    /// Increments the drag-suppression depth and returns the new depth.
    @MainActor
    public func beginWindowDragSuppression() -> Int {
        let next = windowDragSuppressionDepth + 1
        objc_setAssociatedObject(
            self,
            NSWindow.dragSuppressionDepthKey,
            NSNumber(value: next),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return next
    }

    /// Decrements the drag-suppression depth (floored at zero) and returns it,
    /// clearing the association entirely once it reaches zero.
    @MainActor
    @discardableResult
    public func endWindowDragSuppression() -> Int {
        let next = max(0, windowDragSuppressionDepth - 1)
        if next == 0 {
            objc_setAssociatedObject(
                self,
                NSWindow.dragSuppressionDepthKey,
                nil,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        } else {
            objc_setAssociatedObject(
                self,
                NSWindow.dragSuppressionDepthKey,
                NSNumber(value: next),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        return next
    }

    /// The reason for the active window-move suppression sequence, if one is open.
    @MainActor
    public var activeWindowMoveSuppressionSequenceReason: WindowMoveSuppressionReason? {
        guard let state = objc_getAssociatedObject(self, NSWindow.moveSuppressionSequenceKey)
            as? WindowMoveSuppressionSequenceState else {
            return nil
        }
        return state.reason
    }

    /// Opens a window-move suppression sequence for `reason`, making the window
    /// immovable and recording its prior movability. If a sequence is already
    /// open, re-asserts immovability and returns the existing reason.
    @MainActor
    @discardableResult
    public func beginWindowMoveSuppressionSequence(
        reason: WindowMoveSuppressionReason
    ) -> WindowMoveSuppressionReason? {
        if let activeReason = activeWindowMoveSuppressionSequenceReason {
            ensureWindowMoveSuppressionSequenceIsImmovable()
            return activeReason
        }

        let previousMovableState = isMovable
        _ = beginWindowDragSuppression()
        if isMovable {
            isMovable = false
        }
        let state = WindowMoveSuppressionSequenceState(
            reason: reason,
            previousMovableState: previousMovableState
        )
        objc_setAssociatedObject(
            self,
            NSWindow.moveSuppressionSequenceKey,
            state,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return reason
    }

    /// Re-asserts immovability while a suppression sequence is open, in case a
    /// later AppKit pass re-enabled movement.
    @MainActor
    public func ensureWindowMoveSuppressionSequenceIsImmovable() {
        guard activeWindowMoveSuppressionSequenceReason != nil, isMovable else {
            return
        }
        isMovable = false
    }

    /// Closes the active window-move suppression sequence, restoring the prior
    /// movability, and returns the reason it had been opened for.
    @MainActor
    @discardableResult
    public func finishWindowMoveSuppressionSequence() -> WindowMoveSuppressionReason? {
        guard let state = objc_getAssociatedObject(self, NSWindow.moveSuppressionSequenceKey)
            as? WindowMoveSuppressionSequenceState else {
            return nil
        }

        objc_setAssociatedObject(
            self,
            NSWindow.moveSuppressionSequenceKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        _ = endWindowDragSuppression()
        restoreWindowDragging(previousMovableState: state.previousMovableState)
        return state.reason
    }

    /// Restores `isMovable` to `previousMovableState` (no-op when it is `nil`).
    @MainActor
    public func restoreWindowDragging(previousMovableState: Bool?) {
        guard let previousMovableState else { return }
        if isMovable != previousMovableState {
            isMovable = previousMovableState
        }
    }

    /// Fully tears down any suppression sequence and drains the drag-suppression
    /// depth back to zero, returning the final depth.
    @MainActor
    @discardableResult
    public func clearWindowDragSuppression() -> Int {
        if activeWindowMoveSuppressionSequenceReason != nil {
            _ = finishWindowMoveSuppressionSequence()
        }
        var depth = windowDragSuppressionDepth
        while depth > 0 {
            depth = endWindowDragSuppression()
        }
        return depth
    }

    /// Temporarily enables window movability for explicit drag-handle drags, then
    /// restores the previous movability state after `body` finishes.
    @MainActor
    @discardableResult
    public func withTemporaryWindowMovableEnabled(_ body: () -> Void) -> Bool? {
        let previousMovableState = isMovable
        if !previousMovableState {
            isMovable = true
        }
        defer {
            if isMovable != previousMovableState {
                isMovable = previousMovableState
            }
        }

        body()
        return previousMovableState
    }
}
