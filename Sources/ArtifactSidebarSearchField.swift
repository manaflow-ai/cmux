import SwiftUI

/// AppKit-backed search field that exposes deterministic main-window focus.
struct ArtifactSidebarSearchField: NSViewRepresentable {
    let value: String
    let placeholder: String
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> ArtifactSidebarSearchFieldView {
        ArtifactSidebarSearchFieldView(frame: .zero)
    }

    func updateNSView(_ searchField: ArtifactSidebarSearchFieldView, context: Context) {
        searchField.update(value: value, placeholder: placeholder, onChange: onChange)
        searchField.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}
