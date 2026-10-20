public import AppKit

/// Scroll-to-focus (cmux.json `layout.focusPaneOnScroll`, u2246): the start
/// of a scroll that passes through to a pane focuses that pane, like a
/// click, so terminals, browsers, Markdown, agent chats and Home all follow
/// one rule. The layout's monitor sees the scroll before the pane's view, so
/// no pane kind needs its own code.
///
/// Focus stays put when:
/// - the setting is off;
/// - the event is momentum (a coast from a gesture that started elsewhere);
/// - the layout scrolls the event itself (a strip or row scroll keeps its
///   own focus rule, `ColumnViewOffset.focusAfterScroll`);
/// - a key was typed less than ``scrollFocusTypingGrace`` ago, so a
///   scroll never pulls focus out of the field a person is typing in;
/// - the window is not the key window;
/// - the pane under the pointer is already focused.
extension LayoutRootView {
    /// How long after a key-down a scroll leaves focus where it is.
    static let scrollFocusTypingGrace: TimeInterval = 1

    /// Focuses the active screen's pane under `locationInWindow` when the
    /// rules above allow it. Called once per gesture (its first pass-through
    /// event) or per wheel notch, never for momentum.
    func focusPaneForPassThroughScroll(at locationInWindow: NSPoint) {
        guard model.focusesPaneOnScroll, let window, scrollFocusSignals.windowIsKey(window),
              scrollFocusSignals.secondsSinceKeyDown() >= Self.scrollFocusTypingGrace,
              bounds.contains(convert(locationInWindow, from: nil)),
              let active = model.activeScreenID, let view = screenViews[active],
              let pane = view.pane(at: view.convert(locationInWindow, from: nil)),
              pane != model.focusedPane else { return }
        model.focus(pane, source: .scroll)
    }
}
