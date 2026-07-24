import AppKit
import SwiftUI

extension cmuxApp {
    @ViewBuilder
    func surfaceNavigationCommandButtons() -> some View {
        splitCommandButton(
            title: String(
                localized: "menu.view.nextSurface",
                defaultValue: "Next Surface"
            ),
            shortcut: menuShortcut(for: .nextSurface)
        ) {
            activeTabManager.selectNextSurface()
        }
        splitCommandButton(
            title: String(
                localized: "menu.view.previousSurface",
                defaultValue: "Previous Surface"
            ),
            shortcut: menuShortcut(for: .prevSurface)
        ) {
            activeTabManager.selectPreviousSurface()
        }
        splitCommandButton(
            title: String(
                localized: "shortcut.moveSurfaceLeft.label",
                defaultValue: "Reorder Surface Left"
            ),
            shortcut: menuShortcut(for: .moveSurfaceLeft)
        ) {
            activeTabManager.selectedWorkspace?.moveSelectedSurface(by: -1)
        }
        splitCommandButton(
            title: String(
                localized: "shortcut.moveSurfaceRight.label",
                defaultValue: "Reorder Surface Right"
            ),
            shortcut: menuShortcut(for: .moveSurfaceRight)
        ) {
            activeTabManager.selectedWorkspace?.moveSelectedSurface(by: 1)
        }
        ForEach(SurfacePaneMovement.allCases, id: \.self) { movement in
            splitCommandButton(
                title: movement.title,
                shortcut: menuShortcut(for: movement.shortcutAction)
            ) {
                let manager = activeTabManager
                if AppDelegate.shared?.performSurfacePaneMovement(
                    movement,
                    tabManager: manager,
                    preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
                ) != true {
                    NSSound.beep()
                }
            }
        }
    }
}
