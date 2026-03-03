import SwiftUI

@MainActor
final class SidebarSelectionState: ObservableObject {
    @Published var selection: SidebarSelection
    @Published var isSchedulerVisible: Bool = false

    init(selection: SidebarSelection = .tabs, isSchedulerVisible: Bool = false) {
        self.selection = selection
        self.isSchedulerVisible = isSchedulerVisible
    }
}
