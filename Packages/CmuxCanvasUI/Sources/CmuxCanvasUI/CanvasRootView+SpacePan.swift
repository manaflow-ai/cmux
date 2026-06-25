import AppKit

/// Figma-style Space+click-drag panning for ``CanvasRootView``.
extension CanvasRootView {
    static let spacePanKeyCode: UInt16 = 49

    struct SpacePanSession {
        let startWindowPoint: CGPoint
        let startClipOrigin: CGPoint
    }

    func handleSpacePanEvent(_ event: NSEvent) -> NSEvent? {
        guard canvasSpacePanShouldHandleEvents(isWorkspaceVisible: isWorkspaceVisible) else {
            cancelSpacePan()
            return event
        }
        switch event.type {
        case .keyDown:
            guard isSpacePanKeyEvent(event) else { return event }
            isSpacePanKeyDown = true
            if event.isARepeat {
                return canvasSpacePanShouldConsumeSpaceKeyRepeat(
                    didConsumeSpaceKey: didConsumeSpacePanKeyDown,
                    isPanning: spacePanSession != nil
                ) ? nil : event
            }
            didConsumeSpacePanKeyDown = shouldConsumeSpacePanKeyEvent()
            if didConsumeSpacePanKeyDown {
                return nil
            }
            return event

        case .keyUp:
            guard isSpacePanKeyEvent(event) else { return event }
            isSpacePanKeyDown = false
            let shouldConsume = didConsumeSpacePanKeyDown || spacePanSession != nil
            didConsumeSpacePanKeyDown = false
            return shouldConsume ? nil : event

        case .leftMouseDown:
            refreshSpacePanKeyState()
            let pointerInsideCanvas = bounds.contains(convert(event.locationInWindow, from: nil))
            guard canvasSpacePanCanBegin(
                didConsumeSpaceKey: didConsumeSpacePanKeyDown,
                isPhysicalSpaceKeyPressed: Self.isPhysicalSpaceKeyPressed,
                isPointerInsideCanvas: pointerInsideCanvas
            ) else {
                return event
            }
            beginSpacePan(with: event)
            return nil

        case .leftMouseDragged:
            guard spacePanSession != nil else { return event }
            updateSpacePan(with: event)
            return nil

        case .leftMouseUp:
            guard spacePanSession != nil else { return event }
            finishSpacePan()
            return nil

        default:
            return event
        }
    }

    func cancelSpacePan() {
        spacePanSession = nil
        isSpacePanKeyDown = false
        didConsumeSpacePanKeyDown = false
        popSpacePanCursorIfNeeded()
    }

    private static var isPhysicalSpaceKeyPressed: Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(spacePanKeyCode))
    }

    private func isSpacePanKeyEvent(_ event: NSEvent) -> Bool {
        guard event.keyCode == Self.spacePanKeyCode else { return false }
        let reservedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        return event.modifierFlags.intersection(reservedModifiers).isEmpty
    }

    private func shouldConsumeSpacePanKeyEvent() -> Bool {
        guard let window else { return false }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(location) else { return false }
        // Preserve normal terminal/text/control entry when keyboard focus is
        // not owned by the canvas background. If the key was not swallowed, the
        // later mouse-down must not start a pan because a literal Space may
        // already have been delivered to that responder.
        return canvasSpacePanShouldConsumeSpaceKey(
            isPointerInsideCanvas: true,
            canInterceptKeyboardTarget: canInterceptSpacePanKeyboardTarget(in: window),
            isPanning: spacePanSession != nil
        )
    }

    private func canInterceptSpacePanKeyboardTarget(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return true }
        if responder === window {
            return true
        }
        if canvasSpacePanIsTextInputOrControlResponder(responder) {
            return false
        }
        guard let view = responder as? NSView else { return false }
        if isPaneResponder(view) {
            return false
        }
        return view === self || view.isDescendant(of: self)
    }

    private func isPaneResponder(_ responder: NSView) -> Bool {
        return paneViews.values.contains { paneView in
            responder === paneView || responder.isDescendant(of: paneView)
        }
    }

    private func refreshSpacePanKeyState() {
        guard !Self.isPhysicalSpaceKeyPressed else { return }
        isSpacePanKeyDown = false
        didConsumeSpacePanKeyDown = false
    }

    private func beginSpacePan(with event: NSEvent) {
        spacePanSession = SpacePanSession(
            startWindowPoint: event.locationInWindow,
            startClipOrigin: scrollView.contentView.bounds.origin
        )
        overviewRestore = nil
        pushSpacePanCursorIfNeeded()
    }

    private func updateSpacePan(with event: NSEvent) {
        guard let session = spacePanSession else { return }
        let origin = canvasSpacePanClipOrigin(
            startClipOrigin: session.startClipOrigin,
            startWindowPoint: session.startWindowPoint,
            currentWindowPoint: event.locationInWindow,
            magnification: scrollView.magnification
        )
        let clipView = scrollView.contentView
        let constrained = clipView.constrainBoundsRect(CGRect(origin: origin, size: clipView.bounds.size))
        clipView.setBoundsOrigin(constrained.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func finishSpacePan() {
        guard spacePanSession != nil else { return }
        spacePanSession = nil
        popSpacePanCursorIfNeeded()
        flushViewportDidScroll()
        callbacks.onViewportSettled(window)
    }

    private func pushSpacePanCursorIfNeeded() {
        guard !didPushSpacePanCursor else { return }
        NSCursor.closedHand.push()
        didPushSpacePanCursor = true
    }

    private func popSpacePanCursorIfNeeded() {
        guard didPushSpacePanCursor else { return }
        NSCursor.pop()
        didPushSpacePanCursor = false
    }
}

func canvasSpacePanClipOrigin(
    startClipOrigin: CGPoint,
    startWindowPoint: CGPoint,
    currentWindowPoint: CGPoint,
    magnification: CGFloat
) -> CGPoint {
    let scale = max(magnification, 0.0001)
    let dx = (currentWindowPoint.x - startWindowPoint.x) / scale
    let dy = (currentWindowPoint.y - startWindowPoint.y) / scale
    return CGPoint(
        x: startClipOrigin.x - dx,
        y: startClipOrigin.y + dy
    )
}

func canvasSpacePanShouldConsumeSpaceKey(
    isPointerInsideCanvas: Bool,
    canInterceptKeyboardTarget: Bool,
    isPanning: Bool
) -> Bool {
    isPanning || (isPointerInsideCanvas && canInterceptKeyboardTarget)
}

func canvasSpacePanShouldConsumeSpaceKeyRepeat(
    didConsumeSpaceKey: Bool,
    isPanning: Bool
) -> Bool {
    didConsumeSpaceKey || isPanning
}

func canvasSpacePanCanBegin(
    didConsumeSpaceKey: Bool,
    isPhysicalSpaceKeyPressed: Bool,
    isPointerInsideCanvas: Bool
) -> Bool {
    didConsumeSpaceKey && isPhysicalSpaceKeyPressed && isPointerInsideCanvas
}

func canvasSpacePanShouldHandleEvents(isWorkspaceVisible: Bool) -> Bool {
    isWorkspaceVisible
}

private func canvasSpacePanIsTextInputOrControlResponder(_ responder: NSResponder) -> Bool {
    if responder is NSText || responder is any NSTextInputClient {
        return true
    }
    return responder is NSControl
}
