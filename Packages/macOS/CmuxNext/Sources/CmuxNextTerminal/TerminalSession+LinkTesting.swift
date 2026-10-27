public import AppKit

// Live checks drive a terminal's link pointer through the surface view's own mouse and key paths.
#if DEBUG
extension TerminalSession {
    /// Moves the pointer over viewport cell (`column`, `row`) as a mouse does, with
    /// `flags` held (live checks): the view's own mouse-move path.
    public func hoverLinkForTesting(column: Int, row: Int, flags: NSEvent.ModifierFlags = .command) {
        guard let event = surfaceView.linkTestEvent(.mouseMoved, column: column, row: row, flags: flags) else { return }
        surfaceView.linkPointer.testPointer = surfaceView.convert(event.locationInWindow, from: nil)
        surfaceView.linkPointer.testFlags = flags
        surfaceView.mouseMoved(with: event)
    }

    /// A left click on viewport cell (`column`, `row`) with `flags` held, through the
    /// view's own press and release handlers (live checks).
    public func clickLinkForTesting(column: Int, row: Int, flags: NSEvent.ModifierFlags = .command) {
        guard let down = surfaceView.linkTestEvent(.leftMouseDown, column: column, row: row, flags: flags),
              let up = surfaceView.linkTestEvent(.leftMouseUp, column: column, row: row, flags: flags) else { return }
        surfaceView.linkPointer.testPointer = surfaceView.convert(down.locationInWindow, from: nil)
        surfaceView.linkPointer.testFlags = flags
        surfaceView.mouseDown(with: down)
        surfaceView.mouseUp(with: up)
    }

    /// A left press on one cell, a drag to another and the release there, with `flags`
    /// held throughout (live checks).
    public func dragForTesting(from: (column: Int, row: Int), to: (column: Int, row: Int), flags: NSEvent.ModifierFlags = .command) {
        guard let down = surfaceView.linkTestEvent(.leftMouseDown, column: from.column, row: from.row, flags: flags),
              let drag = surfaceView.linkTestEvent(.leftMouseDragged, column: to.column, row: to.row, flags: flags),
              let up = surfaceView.linkTestEvent(.leftMouseUp, column: to.column, row: to.row, flags: flags) else { return }
        surfaceView.linkPointer.testPointer = surfaceView.convert(down.locationInWindow, from: nil)
        surfaceView.linkPointer.testFlags = flags
        surfaceView.mouseDown(with: down)
        surfaceView.linkPointer.testPointer = surfaceView.convert(drag.locationInWindow, from: nil)
        surfaceView.mouseDragged(with: drag)
        surfaceView.mouseUp(with: up)
    }

    /// Modifier keys went down or up with the pointer still (live checks): the key path
    /// when this terminal has focus, the app-wide watcher's either way.
    public func modifiersChangedForTesting(_ flags: NSEvent.ModifierFlags) {
        surfaceView.linkPointer.testFlags = flags
        // A Command key event as AppKit delivers it: flagsChanged, left Command (key code 55).
        let key = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: flags.contains(.command))
        key?.type = .flagsChanged
        key?.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        if surfaceView.isFirstResponder, let key, let event = NSEvent(cgEvent: key) {
            surfaceView.flagsChanged(with: event)
        }
        surfaceView.linkPointer.modifiersChanged(flags)
    }

    /// The wrapped link under the pointer and whether the pointer shows the pointing hand.
    public var linkPointerStateForTesting: (wrapped: String?, pointingHand: Bool) {
        (surfaceView.linkPointer.wrapped?.text, surfaceView.cursor == .pointingHand)
    }
}
#endif
