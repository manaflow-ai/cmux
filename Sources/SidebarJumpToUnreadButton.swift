import AppKit
import Combine
import SwiftUI

/// What the sidebar's Jump to Unread bar shows for a given unread count and
/// configured shortcut. Kept separate from the view so the label, tooltip and
/// visibility rules are testable without hosting SwiftUI.
struct SidebarJumpToUnreadButtonPresentation: Equatable {
    /// A turn arrow reads as "go there"; straight down arrows read as download.
    static let systemName = "arrow.turn.down.right"
    static let maxShownCount = 99

    let label: String
    let helpText: String
    /// The badge text, nil when nothing is unread (the bar is hidden then).
    let countText: String?

    var isVisible: Bool { countText != nil }

    static func resolve(
        unreadCount: Int,
        shortcut: StoredShortcut
    ) -> SidebarJumpToUnreadButtonPresentation {
        let action = KeyboardShortcutSettings.Action.jumpToUnread
        let title = action.label
        return SidebarJumpToUnreadButtonPresentation(
            label: String(localized: "sidebar.jumpToUnread.button", defaultValue: "Jump to unread"),
            helpText: shortcut.isUnbound ? title : action.tooltip(title, shortcut: shortcut),
            countText: unreadCount > 0
                ? (unreadCount > maxShownCount ? "\(maxShownCount)+" : "\(unreadCount)")
                : nil
        )
    }
}

extension View {
    /// Stacks the Jump to Unread bar above the footer's button row.
    func sidebarJumpToUnreadBar(presentationMode: WorkspacePresentationModeSettings.Mode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarJumpToUnreadButton(presentationMode: presentationMode)
            frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Floating "Jump to unread" glass button above the sidebar footer, at its
/// leading edge: the on-screen ⇧⌘U. It runs `AppDelegate.jumpToLatestUnread()`, the same path as the
/// Notifications menu item, the command palette and the configured shortcut,
/// and only exists while something is unread.
///
/// Unread state is observed here rather than in `SidebarFooterButtons`: the
/// store's menu snapshot is reduced to a deduplicated unread count, so
/// notification churn re-renders only this view, and only when the count
/// changes.
struct SidebarJumpToUnreadButton: View {
    @Environment(\.cmuxAccentColor) private var cmuxAccent

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
        let resolved = presentation
        Group {
            if SidebarFooterPresentationPolicy.isVisible(.jumpToUnread, presentationMode: presentationMode),
               resolved.isVisible {
                button(resolved)
            }
        }
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

    private func button(_ resolved: SidebarJumpToUnreadButtonPresentation) -> some View {
        Button {
            AppDelegate.shared?.jumpToLatestUnread()
        } label: {
            HStack(spacing: 6) {
                CmuxSystemSymbolImage(
                    systemName: SidebarJumpToUnreadButtonPresentation.systemName,
                    pointSize: 11,
                    weight: .semibold,
                    tint: cmuxAccent.color
                )
                Text(resolved.label)
                    .cmuxFont(size: 12, weight: .medium)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                if let countText = resolved.countText {
                    Text(countText)
                        .cmuxFont(size: 9, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(cmuxAccent.color))
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(SidebarJumpToUnreadGlassButtonStyle())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .safeHelp(resolved.helpText)
        .accessibilityLabel(resolved.label)
        .accessibilityValue(resolved.countText ?? "")
        .accessibilityIdentifier("SidebarJumpToUnreadButton")
    }
}

/// A floating Liquid Glass capsule (a material capsule before macOS 26) with
/// a hairline rim and a soft shadow; brighter on hover, pressed in on click.
private struct SidebarJumpToUnreadGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarJumpToUnreadGlassButtonBody(configuration: configuration)
    }
}

private struct SidebarJumpToUnreadGlassButtonBody: View {
    let configuration: SidebarJumpToUnreadGlassButtonStyle.Configuration
    @State private var isHovered = false

    private var highlightOpacity: Double {
        if configuration.isPressed { return 0.0 }
        return isHovered ? 0.06 : 0.0
    }

    var body: some View {
        configuration.label
            .sidebarJumpToUnreadGlass()
            .overlay(Capsule().fill(Color.white.opacity(highlightOpacity)).allowsHitTesting(false))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.24), radius: 8, y: 3)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .onHover { isHovered = $0 }
    }
}

private extension View {
    @ViewBuilder
    func sidebarJumpToUnreadGlass() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
        }
        #else
        background(.regularMaterial, in: Capsule())
        #endif
    }
}
