import SwiftUI

/// Gives a project panel's search field keyboard focus when its panel is asked
/// to start find.
///
/// Apply it to the `TextField` itself. The modifier owns the field's
/// `FocusState` and listens for `.projectPanelSearchFocus` posted for `panelID`,
/// so the field and its focus request cannot drift apart.
struct ProjectPanelSearchFieldModifier: ViewModifier {
    let panelID: UUID
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onReceive(NotificationCenter.default.publisher(for: .projectPanelSearchFocus)) { notification in
                guard notification.object as? UUID == panelID else { return }
                isFocused = true
            }
    }
}

extension View {
    /// Makes this search field take focus when the project panel `panelID` is
    /// asked to start find.
    func projectPanelSearchField(panelID: UUID) -> some View {
        modifier(ProjectPanelSearchFieldModifier(panelID: panelID))
    }
}
