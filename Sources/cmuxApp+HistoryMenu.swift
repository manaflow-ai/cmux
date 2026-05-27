import AppKit
import SwiftUI

extension cmuxApp {
    @CommandsBuilder
    var historyCommands: some Commands {
        CommandMenu(String(localized: "menu.history.title", defaultValue: "History")) {
            let historyTabManager = activeTabManager
            let recentlyFocusedSnapshot = recentlyFocusedMenuSnapshot(manager: historyTabManager)
            let recentlyClosedSnapshot = recentlyClosedMenuSnapshot

            splitCommandButton(title: String(localized: "menu.history.focusBack", defaultValue: "Focus Back"), shortcut: menuShortcut(for: .focusHistoryBack)) {
                historyTabManager.navigateBack()
            }
            .disabled(!canNavigateFocusHistoryBack)

            splitCommandButton(title: String(localized: "menu.history.focusForward", defaultValue: "Focus Forward"), shortcut: menuShortcut(for: .focusHistoryForward)) {
                historyTabManager.navigateForward()
            }
            .disabled(!canNavigateFocusHistoryForward)

            Divider()

            recentlyFocusedMenuSection(
                manager: historyTabManager,
                snapshot: recentlyFocusedSnapshot
            )

            Divider()

            splitCommandButton(title: String(localized: "menu.history.reopenLastClosed", defaultValue: "Reopen Last Closed"), shortcut: menuShortcut(for: .reopenClosedBrowserPanel)) {
                if AppDelegate.shared?.reopenMostRecentlyClosedItem(preferredTabManager: historyTabManager) != true {
                    NSSound.beep()
                }
            }

            recentlyClosedMenuSection(
                manager: historyTabManager,
                snapshot: recentlyClosedSnapshot
            )

            Divider()

            splitCommandButton(title: String(localized: "menu.file.restorePreviousAppLaunch", defaultValue: "Restore Previous Launch"), shortcut: menuShortcut(for: .reopenPreviousSession)) {
                if AppDelegate.shared?.reopenPreviousSession() != true {
                    NSSound.beep()
                }
            }
        }
    }

    @ViewBuilder
    private func recentlyFocusedMenuSection(
        manager: TabManager,
        snapshot: FocusHistoryMenuSnapshot
    ) -> some View {
        Button(historyMenuSectionTitle(
            title: String(localized: "menu.history.recentlyFocused", defaultValue: "Recently Focused"),
            subtitle: String(localized: "menu.history.recentlyFocused.subtitle", defaultValue: "Most recent focus targets")
        )) {}
            .disabled(true)

        if snapshot.items.isEmpty {
            Button(String(localized: "menu.history.noFocusHistory", defaultValue: "No Focus History")) {}
                .disabled(true)
        } else {
            ForEach(snapshot.items, id: \.historyIndex) { item in
                Button(FocusHistoryMenuFormatter.menuTitle(for: item)) {
                    if !manager.navigateToFocusHistoryMenuItem(item) {
                        NSSound.beep()
                    }
                }
                .disabled(!item.isNavigable)
            }
        }
    }

    @ViewBuilder
    private func recentlyClosedMenuSection(
        manager: TabManager,
        snapshot: ClosedItemHistoryMenuSnapshot
    ) -> some View {
        Button(historyMenuSectionTitle(
            title: String(localized: "menu.history.recentlyClosed", defaultValue: "Recently Closed"),
            subtitle: String(localized: "menu.history.recentlyClosed.subtitle", defaultValue: "Tabs, workspaces, and windows")
        )) {}
            .disabled(true)

        if snapshot.items.isEmpty {
            Button(String(localized: "menu.history.recentlyClosed.empty", defaultValue: "No Recently Closed Items")) {}
                .disabled(true)
        } else {
            ForEach(snapshot.items) { item in
                Button(item.menuTitle) {
                    if AppDelegate.shared?.reopenClosedHistoryItem(
                        id: item.id,
                        preferredTabManager: manager
                    ) != true {
                        NSSound.beep()
                    }
                }
            }
        }
    }

    private var canNavigateFocusHistoryBack: Bool {
        let _ = focusHistoryMenuInvalidator.revision
        let manager = activeTabManager
        return manager.canNavigateBack
    }

    private var canNavigateFocusHistoryForward: Bool {
        let _ = focusHistoryMenuInvalidator.revision
        let manager = activeTabManager
        return manager.canNavigateForward
    }

    private var recentlyClosedMenuSnapshot: ClosedItemHistoryMenuSnapshot {
        let _ = closedItemHistoryStore.revision
        return closedItemHistoryStore.menuSnapshot(maxItemCount: 10)
    }

    private func historyMenuSectionTitle(title: String, subtitle: String) -> String {
        HistoryMenuLineFormatter.titleWithSubtitle(title: title, subtitle: subtitle)
    }

    private func recentlyFocusedMenuSnapshot(manager: TabManager) -> FocusHistoryMenuSnapshot {
        let _ = focusHistoryMenuInvalidator.revision
        let back = manager.focusHistoryMenuSnapshot(direction: .back)
        let forward = manager.focusHistoryMenuSnapshot(direction: .forward)
        return FocusHistoryMenuSnapshotBuilder.recentlyFocused(
            back: back,
            forward: forward,
            maxItemCount: 10
        )
    }

}
