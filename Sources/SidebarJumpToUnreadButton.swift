import AppKit
import Combine
import SwiftUI

/// What the footer's Jump to Latest Unread button shows for a given unread
/// state and configured shortcut. Kept separate from the view so the title,
/// tooltip and enablement rules are testable without hosting SwiftUI.
struct SidebarJumpToUnreadButtonPresentation: Equatable {
    /// Same glyph as the notifications popover's "Jump to Latest" button.
    static let systemName = "arrow.down.to.line"

    let title: String
    let helpText: String
    let isEnabled: Bool

    static func resolve(
        hasUnreadNotifications: Bool,
        shortcut: StoredShortcut
    ) -> SidebarJumpToUnreadButtonPresentation {
        let action = KeyboardShortcutSettings.Action.jumpToUnread
        let title = action.label
        return SidebarJumpToUnreadButtonPresentation(
            title: title,
            helpText: shortcut.isUnbound ? title : action.tooltip(title, shortcut: shortcut),
            isEnabled: hasUnreadNotifications
        )
    }
}

/// Sidebar-footer button for Jump to Latest Unread, pinned to the trailing
/// edge of the footer row. It runs `AppDelegate.jumpToLatestUnread()`, the same
/// path as the Notifications menu item, the command palette and the configured
/// shortcut, and is enabled under the same rule as that menu item.
///
/// Unread state is observed here rather than in `SidebarFooterButtons`: the
/// store's menu snapshot is reduced to a deduplicated Bool, so notification
/// churn re-renders only this button, and only when its enablement flips.
struct SidebarJumpToUnreadButton: View {
    private let buttonSize = SidebarFooterButtonMetrics.buttonSize
    private let iconSize: CGFloat = 12

    let presentationMode: WorkspacePresentationModeSettings.Mode

    @State private var hasUnreadNotifications: Bool
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    init(presentationMode: WorkspacePresentationModeSettings.Mode) {
        self.presentationMode = presentationMode
        _hasUnreadNotifications = State(
            initialValue: TerminalNotificationStore.shared.notificationMenuSnapshot.hasUnreadNotifications
        )
    }

    private var presentation: SidebarJumpToUnreadButtonPresentation {
        let _ = keyboardShortcutSettingsObserver.revision
        return .resolve(
            hasUnreadNotifications: hasUnreadNotifications,
            shortcut: KeyboardShortcutSettings.shortcut(for: .jumpToUnread)
        )
    }

    var body: some View {
        if SidebarFooterPresentationPolicy.isVisible(.jumpToUnread, presentationMode: presentationMode) {
            button
                .frame(maxWidth: .infinity, alignment: .trailing)
                .onReceive(
                    TerminalNotificationStore.shared.$notificationMenuSnapshot
                        .map(\.hasUnreadNotifications)
                        .removeDuplicates()
                ) { hasUnread in
                    if hasUnreadNotifications != hasUnread {
                        hasUnreadNotifications = hasUnread
                    }
                }
        }
    }

    private var button: some View {
        let resolved = presentation
        return Button {
            AppDelegate.shared?.jumpToLatestUnread()
        } label: {
            CmuxSystemSymbolImage(
                systemName: SidebarJumpToUnreadButtonPresentation.systemName,
                pointSize: iconSize,
                weight: .medium,
                tint: Color(nsColor: resolved.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor)
            )
            .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .disabled(!resolved.isEnabled)
        .accessibilityElement(children: .ignore)
        .safeHelp(resolved.helpText)
        .accessibilityLabel(resolved.title)
        .accessibilityIdentifier("SidebarJumpToUnreadButton")
    }
}
