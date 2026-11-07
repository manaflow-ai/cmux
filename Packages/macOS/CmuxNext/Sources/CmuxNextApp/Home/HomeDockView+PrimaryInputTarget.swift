import AppKit
import CmuxNextHome

/// The docked Home's tab is an internal page whose content is this view, so the page path
/// (`FocusEffectApplier` `.page`, the key dispatcher's `TabContent.primaryInput`) asks it for a
/// primary input. Both its views are web pages with their own focus (the Messages page gives its
/// message box the keyboard itself, `home.messages.focusComposer`; ``shownPageView`` takes the
/// pane's focus), so neither declares a native one. Up and Down while the pane has the keyboard
/// outside the Messages page step its box's history (``HomeComposerHandoff/historyArrow(_:outside:)``).
extension HomeDockView: PrimaryInputTarget {
    var primaryInputView: NSView? { nil }
    var acceptsRedirectedTyping: Bool { mode == .messages }

    func routesToPrimaryInput(_ event: NSEvent) -> Bool {
        mode == .messages && messages.flatMap { HomeComposerHandoff.historyArrow(event, outside: $0.page) } != nil
    }

    func beginTyping(with event: NSEvent) { if let messages { messages.recallHistory(event, page: messages.page) } }

    func primaryInputShouldTakeKeyboard(from responder: NSResponder?) -> Bool { false }
}
