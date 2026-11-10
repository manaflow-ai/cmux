import AppKit

/// The docked Home's tab is an internal page whose content is this view, so the page path
/// (`FocusEffectApplier` `.page`, the key dispatcher's `TabContent.primaryInput`) asks it for a
/// primary input. Both its views are web pages with their own focus (the Messages page gives its
/// message box the keyboard itself, `home.messages.focusComposer`; ``shownPageView`` takes the
/// pane's focus), so neither declares a native one.
extension HomeDockView: PrimaryInputTarget {
    var primaryInputView: NSView? { nil }

    func routesToPrimaryInput(_ event: NSEvent) -> Bool { false }

    func beginTyping(with event: NSEvent) {}

    func primaryInputShouldTakeKeyboard(from responder: NSResponder?) -> Bool { false }
}
