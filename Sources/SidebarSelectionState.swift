import SwiftUI

@MainActor
final class SidebarSelectionState: ObservableObject {
    @Published var selection: SidebarSelection

    init(selection: SidebarSelection = .tabs) {
        self.selection = selection
    }
}
