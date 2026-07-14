import SwiftUI

@MainActor
final class SidebarSelectionState: ObservableObject {
    @Published var selection: SidebarSelection
    /// True from window creation until the first `.ghosttyDidFocusTab` after
    /// launch is consumed. Lets that first auto-focus keep the cold-launch
    /// board landing instead of immediately flipping to `.tabs` — every
    /// later focus event, or an explicit card/tab selection, clears it and
    /// restores normal focus-follows-selection behavior.
    @Published var isInitialBoardLanding: Bool = true

    init(selection: SidebarSelection = .board) {
        self.selection = selection
    }
}
