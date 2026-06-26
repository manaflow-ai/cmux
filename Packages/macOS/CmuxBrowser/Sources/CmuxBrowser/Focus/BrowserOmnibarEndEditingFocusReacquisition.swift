/// The omnibar end-editing situation that decides whether the address bar should
/// reacquire first-responder focus after its field editor resigned.
///
/// When the omnibar field ends editing, cmux re-focuses it only when the omnibar
/// still wants focus and the responder that took over is not another text field
/// (a deliberate move into a different control must win). The app target inlined
/// this as a free `browserOmnibarShouldReacquireFocusAfterEndEditing(...)`
/// function; it is a pure decision over two booleans with no AppKit responder or
/// `BrowserPanel` reach, so it moves here as a small value type that carries its
/// inputs and exposes the decision as ``shouldReacquireFocus`` (a real value
/// type, not a static-method namespace). The body is a byte-faithful lift.
public struct BrowserOmnibarEndEditingFocusReacquisition: Equatable, Sendable {
    /// `true` when the omnibar still wants first-responder focus.
    public let desiredOmnibarFocus: Bool
    /// `true` when the responder taking over from the omnibar is another text field.
    public let nextResponderIsOtherTextField: Bool

    /// Creates the end-editing focus-reacquisition decision inputs.
    public init(desiredOmnibarFocus: Bool, nextResponderIsOtherTextField: Bool) {
        self.desiredOmnibarFocus = desiredOmnibarFocus
        self.nextResponderIsOtherTextField = nextResponderIsOtherTextField
    }

    /// Whether the omnibar should reacquire focus after its field editor resigned.
    public var shouldReacquireFocus: Bool {
        desiredOmnibarFocus && !nextResponderIsOtherTextField
    }
}
