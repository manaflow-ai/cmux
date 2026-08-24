import AppKit
import CmuxWorkspaces
import SwiftUI

extension cmuxApp {
    @CommandsBuilder
    var historyCommands: some Commands {
        CommandMenu(String(localized: "menu.history.title", defaultValue: "History")) {
            let historyState = focusHistoryMenuInvalidator.state

            splitCommandButton(title: String(localized: "menu.history.focusBack", defaultValue: "Focus Back"), shortcut: menuShortcut(for: .focusHistoryBack)) {
                activeTabManager.navigateBack()
            }
            .disabled(!canNavigateFocusHistoryBack)

            splitCommandButton(title: String(localized: "menu.history.focusForward", defaultValue: "Focus Forward"), shortcut: menuShortcut(for: .focusHistoryForward)) {
                activeTabManager.navigateForward()
            }
            .disabled(!canNavigateFocusHistoryForward)

            Divider()

            recentlyFocusedMenuSection(
                items: historyState.recentlyFocusedItems
            )

            Divider()

            splitCommandButton(title: String(localized: "menu.history.reopenClosedWorkspace", defaultValue: "Reopen Closed Workspace"), shortcut: menuShortcut(for: .reopenClosedWorkspace)) {
                if AppDelegate.shared?.reopenMostRecentlyClosedWorkspace(preferredTabManager: activeTabManager) != true {
                    NSSound.beep()
                }
            }

            splitCommandButton(title: String(localized: "menu.history.reopenLastClosed", defaultValue: "Reopen Last Closed"), shortcut: menuShortcut(for: .reopenClosedBrowserPanel)) {
                if AppDelegate.shared?.reopenMostRecentlyClosedItem(preferredTabManager: activeTabManager) != true {
                    NSSound.beep()
                }
            }

            recentlyClosedMenuSection(
                snapshot: historyState.recentlyClosed
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
        items: [FocusHistoryMenuItem]
    ) -> some View {
        Button(historyMenuSectionTitle(
            title: String(localized: "menu.history.recentlyFocused", defaultValue: "Recently Focused"),
            subtitle: String(localized: "menu.history.recentlyFocused.subtitle", defaultValue: "Most recent focus targets")
        )) {}
            .disabled(true)

        if items.isEmpty {
            Button(String(localized: "menu.history.noFocusHistory", defaultValue: "No Focus History")) {}
                .disabled(true)
        } else {
            ForEach(items, id: \.historyIndex) { item in
                Button(FocusHistoryMenuFormatter.menuTitle(for: item)) {
                    if !activeTabManager.navigateToFocusHistoryMenuItem(item) {
                        NSSound.beep()
                    }
                }
                .disabled(!item.isNavigable)
            }
        }
    }

    @ViewBuilder
    private func recentlyClosedMenuSection(
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
                        preferredTabManager: activeTabManager
                    ) != true {
                        NSSound.beep()
                    }
                }
            }
        }
    }

    private var canNavigateFocusHistoryBack: Bool {
        focusHistoryMenuInvalidator.state.canNavigateBack
    }

    private var canNavigateFocusHistoryForward: Bool {
        focusHistoryMenuInvalidator.state.canNavigateForward
    }

    private func historyMenuSectionTitle(title: String, subtitle: String) -> String {
        HistoryMenuLineFormatter.titleWithSubtitle(title: title, subtitle: subtitle)
    }

}
