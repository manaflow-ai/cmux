import SwiftUI

extension cmuxApp {
    func equalizeSplitsCommandButton() -> some View {
        splitCommandButton(title: String(localized: "command.equalizeSplits.title", defaultValue: "Equalize Splits"), shortcut: menuShortcut(for: .equalizeSplits)) {
            if let workspace = activeTabManager.selectedWorkspace {
                _ = activeTabManager.equalizeSplits(tabId: workspace.id)
            }
        }
    }
}
