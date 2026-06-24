import AppKit

/// Figma-style Space+click-drag panning for ``CanvasRootView``.
extension CanvasRootView {
    static let spacePanKeyCode: UInt16 = 49

    struct SpacePanSession {
        let startWindowPoint: CGPoint
        let startClipOrigin: CGPoint
    }

    func handleSpacePanEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            guard isSpacePanKeyEvent(event) else { return event }
            isSpacePanKeyDown = true
            if shouldConsumeSpacePanKeyEvent() {
                didConsumeSpacePanKeyDown = true
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
            guard isSpacePanArmed, bounds.contains(convert(event.locationInWindow, from: nil)) else {
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

    private var isSpacePanArmed: Bool {
        isSpacePanKeyDown || Self.isPhysicalSpaceKeyPressed
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
        // Preserve normal terminal/text entry when the pointer sits over pane
        // content; the following mouse-down will still enter hand-pan mode if
        // the user is intentionally holding Space and dragging.
        return paneView(at: location) == nil || spacePanSession != nil
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
        let origin = Self.spacePanClipOrigin(
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
        updateLifecycle()
        saveViewportToModel()
        callbacks.onViewportGeometryChanged(window)
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

    static func spacePanClipOrigin(
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
}
