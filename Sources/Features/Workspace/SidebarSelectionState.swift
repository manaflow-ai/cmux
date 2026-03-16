import SwiftUI

@MainActor
final class SidebarSelectionState: ObservableObject {
    // MARK: Properties

    @Published var selection: SidebarSelection

    // MARK: Lifecycle

    init(selection: SidebarSelection = .tabs) {
        self.selection = selection
    }
}
