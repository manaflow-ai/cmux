import UIKit

/// An opaque text position for the terminal input view's hand-rolled
/// ``UITextInput`` conformance.
///
/// ``TerminalInputTextView`` is a remote-terminal proxy: it owns no editable
/// document, so it never exposes real character offsets. UIKit's text-input
/// machinery (IME composition, the dictation placeholder, the "speak selection"
/// action) still requires the view to vend `UITextPosition`/`UITextRange`
/// instances, so this is a sentinel with no addressable offset. It exists only
/// to satisfy the protocol's identity requirements; the geometry/offset methods
/// that would consume it all return neutral values.
final class TerminalInputTextPosition: UITextPosition {}
