import SwiftUI

/// The face of a ``CmuxDialogButtonStyle`` button: the button's focus and enabled state, passed to the
/// ``CmuxDialogButtonView`` that draws it.
struct CmuxDialogButtonFace: View {
    let button: CmuxDialogButton
    let hint: CmuxDialogKeyHint?
    let isPressed: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        CmuxDialogButtonFaceView(button: button, hint: hint, isPressed: isPressed, isFocused: isFocused, isEnabled: isEnabled)
            // A role or key change is another button: AppKit's view keeps both from its init.
            .id("\(button.role.rawValue) \(hint?.glyph ?? "")")
            // The click is the SwiftUI button's: the drawing takes none, the shape under it takes them all.
            .allowsHitTesting(false)
            .background(Color.clear.contentShape(Rectangle()))
    }
}
