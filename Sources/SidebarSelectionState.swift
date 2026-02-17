import SwiftUI

@MainActor
final class SidebarSelectionState: ObservableObject {
    @Published var selection: SidebarSelection = .tabs
}

