import SwiftUI

@MainActor
final class SidebarSelectionState: ObservableObject {
    @Published var selection: SidebarSelection {
        didSet {
            guard selection != oldValue else { return }
            AppDelegate.requestSessionSnapshotDirty(reason: "sidebar.selection")
        }
    }

    init(selection: SidebarSelection = .tabs) {
        self.selection = selection
    }
}
