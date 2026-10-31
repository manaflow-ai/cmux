public import AppKit

/// Focus follows mouse (cmux.json `layout.focusFollowsMouse`, default off; the user,
/// Oct 20: a scroll or hover over another pane must not pull focus out of the field
/// being typed in, but people who want it can turn it on). When on, the pointer
/// entering a pane, or the start of a scroll that passes through to a pane, focuses
/// that pane like a click, so terminals, browsers, Markdown, agent chats and Home all
/// follow one rule. The layout sees the pointer before the pane's view, so no pane
/// kind needs its own code.
///
/// Focus stays put when:
/// - the setting is off (the default);
/// - the event is momentum (a coast from a gesture that started elsewhere);
/// - the layout scrolls the event itself (a strip or row scroll keeps its
///   own focus rule, `ColumnViewOffset.focusAfterScroll`);
/// - a key was typed less than ``scrollFocusTypingGrace`` ago, so the pointer
///   never pulls focus out of the field a person is typing in;
/// - the window is not the key window;
/// - a mouse button is held (a drag or a selection, hover only);
/// - the pane under the pointer is already focused, or (hover) the pointer is
///   still inside the pane it was last over.
extension LayoutRootView {
    /// How long after a key-down the pointer leaves focus where it is.
    static let scrollFocusTypingGrace: TimeInterval = 1

    /// Focuses the active screen's pane under `locationInWindow` when the
    /// rules above allow it. Called once per gesture (its first pass-through
    /// event) or per wheel notch, never for momentum.
    func focusPaneForPassThroughScroll(at locationInWindow: NSPoint) {
        guard let pane = paneAllowedToFollowMouse(at: locationInWindow) else { return }
        model.focus(pane, source: .scroll)
    }

    /// Hover half of focus-follows-mouse: focuses the pane under
    /// `locationInWindow` (window coordinates) when the pointer has just entered
    /// it and the rules above allow it. Returns the pane it focused.
    @discardableResult
    public func focusPaneForPointerHover(at locationInWindow: NSPoint) -> PaneID? {
        guard model.focusFollowsMouse else {
            hoveredPane = nil
            return nil
        }
        let under = paneUnderPointer(at: locationInWindow)
        let entered = under != hoveredPane
        hoveredPane = under
        guard entered, !scrollFocusSignals.mouseButtonsDown(), let pane = paneAllowedToFollowMouse(at: locationInWindow) else { return nil }
        model.focus(pane, source: .pointer)
        return pane
    }

    private func paneUnderPointer(at locationInWindow: NSPoint) -> PaneID? {
        guard bounds.contains(convert(locationInWindow, from: nil)),
              let active = model.activeScreenID, let view = screenViews[active] else { return nil }
        return view.pane(at: view.convert(locationInWindow, from: nil))
    }

    private func paneAllowedToFollowMouse(at locationInWindow: NSPoint) -> PaneID? {
        guard model.focusFollowsMouse, let window, scrollFocusSignals.windowIsKey(window),
              scrollFocusSignals.secondsSinceKeyDown() >= Self.scrollFocusTypingGrace,
              let pane = paneUnderPointer(at: locationInWindow), pane != model.focusedPane else { return nil }
        return pane
    }
}
