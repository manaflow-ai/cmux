import AppKit
import Combine
import SwiftUI

/// What the footer's Jump to Latest Unread button shows for a given unread
/// state and configured shortcut. Kept separate from the view so the title,
/// tooltip and enablement rules are testable without hosting SwiftUI.
struct SidebarJumpToUnreadButtonPresentation: Equatable {
    /// An arrow that hops, so the button reads as "jump", not "download".
    static let systemName = "arrowshape.bounce.right"
    static let maxShownCount = 99

    let title: String
    let helpText: String
    let isEnabled: Bool
    /// The unread count shown beside the icon, nil when nothing is unread.
    let countText: String?

    static func resolve(
        unreadCount: Int,
        shortcut: StoredShortcut
    ) -> SidebarJumpToUnreadButtonPresentation {
        let action = KeyboardShortcutSettings.Action.jumpToUnread
        let title = action.label
        return SidebarJumpToUnreadButtonPresentation(
            title: title,
            helpText: shortcut.isUnbound ? title : action.tooltip(title, shortcut: shortcut),
            isEnabled: unreadCount > 0,
            countText: unreadCount > 0
                ? (unreadCount > maxShownCount ? "\(maxShownCount)+" : "\(unreadCount)")
                : nil
        )
    }
}

/// Sidebar-footer button for Jump to Latest Unread, pinned to the trailing
/// edge of the footer row. It runs `AppDelegate.jumpToLatestUnread()`, the same
/// path as the Notifications menu item, the command palette and the configured
/// shortcut, and is enabled under the same rule as that menu item.
///
/// Unread state is observed here rather than in `SidebarFooterButtons`: the
/// store's menu snapshot is reduced to a deduplicated unread count, so
/// notification churn re-renders only this button, and only when the count
/// changes.
///
/// The button is never `.disabled`: macOS shows no tooltip on a disabled
/// control, so with nothing unread it is only dimmed and its action does
/// nothing.
struct SidebarJumpToUnreadButton: View {
    private let buttonSize = SidebarFooterButtonMetrics.buttonSize
    private let iconSize: CGFloat = 12

    let presentationMode: WorkspacePresentationModeSettings.Mode

    @State private var unreadCount: Int
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    init(presentationMode: WorkspacePresentationModeSettings.Mode) {
        self.presentationMode = presentationMode
        _unreadCount = State(
            initialValue: TerminalNotificationStore.shared.notificationMenuSnapshot.unreadCount
        )
    }

    private var presentation: SidebarJumpToUnreadButtonPresentation {
        let _ = keyboardShortcutSettingsObserver.revision
        return .resolve(
            unreadCount: unreadCount,
            shortcut: KeyboardShortcutSettings.shortcut(for: .jumpToUnread)
        )
    }

    var body: some View {
        if SidebarFooterPresentationPolicy.isVisible(.jumpToUnread, presentationMode: presentationMode) {
            button
                .frame(maxWidth: .infinity, alignment: .trailing)
                .onReceive(
                    TerminalNotificationStore.shared.$notificationMenuSnapshot
                        .map(\.unreadCount)
                        .removeDuplicates()
                ) { count in
                    if unreadCount != count {
                        unreadCount = count
                    }
                }
        }
    }

    private var button: some View {
        let resolved = presentation
        let tint = Color(nsColor: resolved.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor)
        return Button {
            guard resolved.isEnabled else { return }
            AppDelegate.shared?.jumpToLatestUnread()
        } label: {
            HStack(spacing: 3) {
                CmuxSystemSymbolImage(
                    systemName: SidebarJumpToUnreadButtonPresentation.systemName,
                    pointSize: iconSize,
                    weight: .medium,
                    tint: tint
                )
                if let countText = resolved.countText {
                    Text(countText)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, resolved.countText == nil ? 0 : 5)
            .frame(minWidth: buttonSize, minHeight: buttonSize, maxHeight: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .accessibilityElement(children: .ignore)
        .safeHelp(resolved.helpText)
        .accessibilityLabel(resolved.title)
        .accessibilityValue(resolved.countText ?? "")
        .accessibilityIdentifier("SidebarJumpToUnreadButton")
    }
}
