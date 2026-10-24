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
            if let dock = AppDelegate.shared?.focusedDockStoreForShortcut(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            ) {
                _ = dock.performShortcutCommand(.selectNextSurface)
                return
            }
            activeTabManager.selectNextSurface()
        }
        splitCommandButton(
            title: String(
                localized: "menu.view.previousSurface",
                defaultValue: "Previous Surface"
            ),
            shortcut: menuShortcut(for: .prevSurface)
        ) {
            if let dock = AppDelegate.shared?.focusedDockStoreForShortcut(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            ) {
                _ = dock.performShortcutCommand(.selectPreviousSurface)
                return
            }
            activeTabManager.selectPreviousSurface()
        }
        splitCommandButton(
            title: String(
                localized: "shortcut.moveSurfaceLeft.label",
                defaultValue: "Reorder Surface Left"
            ),
            shortcut: menuShortcut(for: .moveSurfaceLeft)
        ) {
            if let dock = AppDelegate.shared?.focusedDockStoreForShortcut(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            ) {
                _ = dock.performShortcutCommand(.moveSurface(offset: -1))
                return
            }
            activeTabManager.selectedWorkspace?.moveSelectedSurface(by: -1)
        }
        splitCommandButton(
            title: String(
                localized: "shortcut.moveSurfaceRight.label",
                defaultValue: "Reorder Surface Right"
            ),
            shortcut: menuShortcut(for: .moveSurfaceRight)
        ) {
            if let dock = AppDelegate.shared?.focusedDockStoreForShortcut(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            ) {
                _ = dock.performShortcutCommand(.moveSurface(offset: 1))
                return
            }
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
