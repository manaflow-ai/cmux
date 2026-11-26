import SwiftUI

/// Accessibility wrapper for a sidebar workspace row. Normal rows are combined
/// into a single VoiceOver element with the workspace's title, hint, and
/// Move Up/Down actions. While the row is being renamed inline, the row instead
/// `contain`s its children so the inline rename text field is a reachable,
/// editable accessibility element (otherwise `.combine` flattens it and
/// VoiceOver cannot reach the field).
struct SidebarRowAccessibilityModifier: ViewModifier {
    let isEditing: Bool
    let label: String
    let hint: String
    let moveUpLabel: String
    let moveDownLabel: String
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    /// Applies combined (normal) or contained (editing) accessibility behavior
    /// to the row so the inline field stays reachable while renaming.
    func body(content: Content) -> some View {
        if isEditing {
            content.accessibilityElement(children: .contain)
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(label))
                .accessibilityHint(Text(hint))
                .accessibilityAction(named: Text(moveUpLabel), onMoveUp)
                .accessibilityAction(named: Text(moveDownLabel), onMoveDown)
        }
    }
}
