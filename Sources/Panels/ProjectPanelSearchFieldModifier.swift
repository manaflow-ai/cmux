import AppKit
import SwiftUI

/// Gives a project panel's search field keyboard focus when its panel is asked
/// to start find, and lets the panel recognize the field as its focus owner.
///
/// Apply it to the `TextField` itself. The modifier owns the field's
/// `FocusState` and listens for `.projectPanelSearchFocus` posted for the
/// panel, so the field and its focus request cannot drift apart. It also
/// places a ``ProjectPanelSearchFieldAnchorView`` behind the field, which
/// ``ProjectPanel/ownedFocusIntent(for:in:)`` uses to attribute the field's
/// editor to the panel when the window's focus coordinator asks.
struct ProjectPanelSearchFieldModifier: ViewModifier {
    let panel: ProjectPanel
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .background(ProjectPanelSearchFieldAnchor(panel: panel))
            .onReceive(NotificationCenter.default.publisher(for: .projectPanelSearchFocus)) { notification in
                guard notification.object as? UUID == panel.id else { return }
                isFocused = true
            }
    }
}

extension View {
    /// Makes this search field take focus when `panel` is asked to start find,
    /// and makes `panel` the owner of the field's keyboard focus.
    func projectPanelSearchField(panel: ProjectPanel) -> some View {
        modifier(ProjectPanelSearchFieldModifier(panel: panel))
    }
}

/// Registers a ``ProjectPanelSearchFieldAnchorView`` behind a project panel's
/// search field for as long as the field is mounted.
private struct ProjectPanelSearchFieldAnchor: NSViewRepresentable {
    let panel: ProjectPanel

    func makeNSView(context: Context) -> ProjectPanelSearchFieldAnchorView {
        let view = ProjectPanelSearchFieldAnchorView()
        view.attach(to: panel)
        return view
    }

    func updateNSView(_ view: ProjectPanelSearchFieldAnchorView, context: Context) {
        view.attach(to: panel)
    }

    static func dismantleNSView(_ view: ProjectPanelSearchFieldAnchorView, coordinator: Void) {
        view.detach()
    }
}

/// Sits behind a project panel's search field and identifies the field's
/// keyboard focus for the panel.
///
/// SwiftUI does not expose the `NSTextField` behind a `TextField`, so this
/// view stands in for it: it shares the field's frame, and a responder whose
/// text field is centered inside that frame is the field's editor.
@MainActor
final class ProjectPanelSearchFieldAnchorView: NSView {
    private weak var ownerPanel: ProjectPanel?

    func attach(to panel: ProjectPanel) {
        if ownerPanel !== panel {
            detach()
        }
        ownerPanel = panel
        panel.searchFieldAnchor = self
    }

    func detach() {
        if ownerPanel?.searchFieldAnchor === self {
            ownerPanel?.searchFieldAnchor = nil
        }
        ownerPanel = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Whether `responder` is the search field this view sits behind, or that
    /// field's editor, in `window`.
    func ownsKeyboardFocus(_ responder: NSResponder, in window: NSWindow) -> Bool {
        guard self.window === window else { return false }
        let fieldView: NSView?
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            fieldView = editor.delegate as? NSTextField
        } else {
            fieldView = responder as? NSTextField
        }
        guard let fieldView, fieldView.window === window else { return false }
        let fieldFrame = fieldView.convert(fieldView.bounds, to: nil)
        return convert(bounds, to: nil).contains(NSPoint(x: fieldFrame.midX, y: fieldFrame.midY))
    }
}
