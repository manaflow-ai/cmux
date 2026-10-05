import SwiftUI

/// Value-only menu shared by the legacy row's deferred context menu.
struct SidebarExtensionImportanceMenu: View {
    let importance: Workspace.Importance
    let onSelect: (Workspace.Importance) -> Void

    var body: some View {
        Menu(String(localized: "sidebar.importance.title", defaultValue: "Importance")) {
            ForEach(Workspace.Importance.allCases, id: \.self) { value in
                Button {
                    onSelect(value)
                } label: {
                    Label(value.menuTitle, systemImage: value == importance ? "checkmark" : (value == .none ? "star" : "star.fill"))
                }
            }
        }
    }
}
