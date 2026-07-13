import SwiftUI

@MainActor
final class SidebarSelectionState: ObservableObject {
    @Published var selection: SidebarSelection

    init(selection: SidebarSelection = .board) {
        self.selection = selection
    }
}
