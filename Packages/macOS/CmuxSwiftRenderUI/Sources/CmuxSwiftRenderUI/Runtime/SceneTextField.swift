import AppKit

/// The AppKit field behind a JS sidebar `TextField`, tagged with the
/// ``SceneAutofocusGate`` of the sidebar that mounted it so the gate can tell
/// its own fields apart from every other focusable view in the window.
final class SceneTextField: NSTextField {
    weak var autofocusGate: SceneAutofocusGate?
}
