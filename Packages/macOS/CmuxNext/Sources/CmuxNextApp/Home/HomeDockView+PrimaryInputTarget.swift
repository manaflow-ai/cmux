import AppKit

/// The docked Home's tab is an internal page whose content is this view, so
/// the page path (`FocusEffectApplier` `.page`, the key dispatcher's
/// `TabContent.primaryInput`) reaches Home's message box through it. Before,
/// only a conversation tab (`HomeHostView`) declared one: focusing the dock's
/// pane made the dock view itself first responder, which takes no keys, and
/// typing went nowhere until a click in the transcript. The Messages view
/// forwards to its list and transcript; the Channels page (a web page with its
/// own focus) declares none.
extension HomeDockView: PrimaryInputTarget {
    var primaryInputView: NSView? { mode == .messages ? messages?.primaryInputView : nil }

    /// The Messages view's keys (Home's one key path: `HomeHostView`).
    func routesToPrimaryInput(_ event: NSEvent) -> Bool { mode == .messages && messages?.routesToPrimaryInput(event) == true }

    func beginTyping(with event: NSEvent) { if mode == .messages { messages?.beginTyping(with: event) } }

    func primaryInputShouldTakeKeyboard(from responder: NSResponder?) -> Bool {
        guard mode == .messages, let messages else { return false }
        return messages.primaryInputShouldTakeKeyboard(from: responder)
    }
}
