import AppKit
import SwiftUI

/// A ``CmuxDialogButtonView`` that only draws (``CmuxDialogButtonView/isFace``): the SwiftUI button around it takes
/// the clicks, the keys and the focus.
struct CmuxDialogButtonFaceView: NSViewRepresentable {
    let button: CmuxDialogButton
    let hint: CmuxDialogKeyHint?
    let isPressed: Bool
    let isFocused: Bool
    let isEnabled: Bool

    func makeNSView(context: Context) -> CmuxDialogButtonView {
        let view = CmuxDialogButtonView(button, hint: hint, target: nil, action: Self.noAction)
        view.isFace = true
        view.action = nil
        // SwiftUI places the view by its frame: no Auto Layout height of its own.
        NSLayoutConstraint.deactivate(view.constraints.filter { $0.firstItem === view && $0.firstAttribute == .height })
        view.translatesAutoresizingMaskIntoConstraints = true
        view.setAccessibilityElement(false)
        update(view)
        return view
    }

    /// The init wants an action; a face sends none (SwiftUI's button runs it).
    private static let noAction = Selector(("cmuxDialogFaceSendsNoAction"))

    func updateNSView(_ view: CmuxDialogButtonView, context: Context) { update(view) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: CmuxDialogButtonView, context: Context) -> CGSize? {
        view.intrinsicContentSize
    }

    private func update(_ view: CmuxDialogButtonView) {
        view.retitle(button.title)
        if view.isEnabled != isEnabled { view.isEnabled = isEnabled }
        view.hasFocus = isFocused
        let state: CmuxDialogButtonLook.State? = isPressed ? .pressed : nil
        if view.previewState != state { view.previewState = state }
    }
}
