import Observation
import SwiftUI

@MainActor
@Observable
final class SidebarSelectionState {
    var selection: SidebarSelection

    init(selection: SidebarSelection = .tabs) {
        self.selection = selection
    }
}
