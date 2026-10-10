import CmuxSettings
import Combine
import SwiftUI

/// What the sidebar's Last unread button shows for a given unread count,
/// shortcut and setting. Kept apart from the view so the label, tooltip and
/// visibility rules are testable without hosting SwiftUI.
struct SidebarJumpToUnreadButtonPresentation: Equatable {
    /// A turn arrow reads as "go there"; straight down arrows read as download.
    static let systemName = "arrow.turn.down.right"
    static let maxShownCount = 99
    /// `sidebar.showJumpToUnreadButton`, which the button's × turns off.
    static let setting = SidebarCatalogSection().showJumpToUnreadButton

    let label: String
    let helpText: String
    /// The badge text, nil when nothing is unread.
    let countText: String?
    /// The configured shortcut, shown on hover to teach it; nil when unbound.
    let shortcutText: String?
    let isVisible: Bool

    static func resolve(
        unreadCount: Int,
        shortcut: StoredShortcut,
        isEnabled: Bool = true
    ) -> SidebarJumpToUnreadButtonPresentation {
        let action = KeyboardShortcutSettings.Action.jumpToUnread
        let title = action.label
        return SidebarJumpToUnreadButtonPresentation(
            label: String(localized: "sidebar.jumpToUnread.title", defaultValue: "Last unread"),
            helpText: shortcut.isUnbound ? title : action.tooltip(title, shortcut: shortcut),
            countText: unreadCount > 0 ? (unreadCount > maxShownCount ? "\(maxShownCount)+" : "\(unreadCount)") : nil,
            shortcutText: shortcut.isUnbound ? nil : shortcut.displayString,
            isVisible: isEnabled && unreadCount > 0
        )
    }
}

extension View {
    /// Puts the Last unread button on its own row above the footer row.
    func sidebarJumpToUnreadBar(presentationMode: WorkspacePresentationModeSettings.Mode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarJumpToUnreadButton(presentationMode: presentationMode)
            frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The on-screen ⇧⌘U: a glass capsule centered above the sidebar footer,
/// shown only while something is unread. At rest it reads "↳ Last unread (3)";
/// on hover the count turns into the configured shortcut and a × follows.
/// One × click asks "Click × again to hide", a second turns
/// `sidebar.showJumpToUnreadButton` off (Settings > Sidebar turns it back on).
/// The jump runs `AppDelegate.jumpToLatestUnread()`, like the menu item and
/// the shortcut. Unread state is reduced to a deduplicated count, so
/// notification churn re-renders only this view, and only when the count changes.
struct SidebarJumpToUnreadButton: View {
    @Environment(\.cmuxAccentColor) private var cmuxAccent
    let presentationMode: WorkspacePresentationModeSettings.Mode
    @State private var unreadCount: Int
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var isHovered = false
    @State private var isCloseHovered = false
    /// After the first × click the capsule asks for a second one.
    @State private var isConfirmingHide = false
    @AppStorage(SidebarJumpToUnreadButtonPresentation.setting.userDefaultsKey)
    private var isEnabled = SidebarJumpToUnreadButtonPresentation.setting.defaultValue
    /// Times the confirm prompt's reset; injected so the delay isn't a bare sleep.
    private let clock: any Clock<Duration>

    init(presentationMode: WorkspacePresentationModeSettings.Mode, clock: any Clock<Duration> = ContinuousClock()) {
        self.presentationMode = presentationMode
        self.clock = clock
        _unreadCount = State(initialValue: TerminalNotificationStore.shared.notificationMenuSnapshot.unreadCount)
    }

    private var presentation: SidebarJumpToUnreadButtonPresentation {
        let _ = keyboardShortcutSettingsObserver.revision
        return .resolve(
            unreadCount: unreadCount,
            shortcut: KeyboardShortcutSettings.shortcut(for: .jumpToUnread),
            isEnabled: isEnabled
        )
    }

    var body: some View {
        let resolved = presentation
        Group {
            if SidebarFooterPresentationPolicy.isVisible(.jumpToUnread, presentationMode: presentationMode),
               resolved.isVisible {
                control(resolved)
                    .contextMenu {
                        Button(String(localized: "sidebar.jumpToUnread.hide", defaultValue: "Hide Jump to Unread Button")) {
                            isEnabled = false
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 8)
                    // Clicking jumps, which can clear the last unread and remove the
                    // capsule under the pointer; onHover(false) never comes then, so
                    // it would return still hovered (or still confirming).
                    .onDisappear {
                        isHovered = false
                        isCloseHovered = false
                        isConfirmingHide = false
                    }
            }
        }
        .task(id: isConfirmingHide) {
            guard isConfirmingHide else { return }
            try? await clock.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { isConfirmingHide = false }
        }
        .onReceive(TerminalNotificationStore.shared.$notificationMenuSnapshot.map(\.unreadCount).removeDuplicates()) { count in
            if unreadCount != count { unreadCount = count }
        }
    }

    /// At rest "↳ Last unread (3)"; on hover "↳ Last unread ⇧⌘U ×";
    /// after one × click "Click × again to hide ×".
    private func control(_ resolved: SidebarJumpToUnreadButtonPresentation) -> some View {
        let showsClose = isHovered || isConfirmingHide
        return HStack(spacing: 4) {
            Button {
                // While confirming, the text is a prompt, not the jump.
                guard !isConfirmingHide else { return }
                AppDelegate.shared?.jumpToLatestUnread()
            } label: {
                HStack(spacing: 6) {
                    if isConfirmingHide {
                        title(String(localized: "sidebar.jumpToUnread.confirmHide", defaultValue: "Click × again to hide"))
                    } else {
                        CmuxSystemSymbolImage(
                            systemName: SidebarJumpToUnreadButtonPresentation.systemName,
                            pointSize: 11,
                            weight: .semibold,
                            tint: cmuxAccent.color
                        )
                        title(resolved.label)
                        // Hovering swaps the count for the key that does the same thing.
                        if isHovered { shortcutLabel(resolved) } else { countBadge(resolved) }
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, showsClose ? 0 : 6)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .safeHelp(resolved.helpText)
            .accessibilityLabel(resolved.label)
            .accessibilityValue(resolved.countText ?? "")
            .accessibilityIdentifier("SidebarJumpToUnreadButton")
            if showsClose {
                // Fades in once the capsule has finished widening, and out at once.
                closeButton.padding(.trailing, 6).transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.12).delay(0.15)),
                    removal: .opacity.animation(.easeOut(duration: 0.06))
                ))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .sidebarJumpToUnreadGlass(hovered: isHovered)
        .onHover { hovering in
            isHovered = hovering
            if !hovering {
                isConfirmingHide = false
                // The × leaves with the hover, before its own onHover(false).
                isCloseHovered = false
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isConfirmingHide)
    }

    @ViewBuilder
    private func countBadge(_ resolved: SidebarJumpToUnreadButtonPresentation) -> some View {
        if let countText = resolved.countText {
            Text(countText).cmuxFont(size: 9, weight: .semibold).monospacedDigit().foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(cmuxAccent.color))
                .fixedSize()
        }
    }

    @ViewBuilder
    private func shortcutLabel(_ resolved: SidebarJumpToUnreadButtonPresentation) -> some View {
        if let shortcutText = resolved.shortcutText {
            Text(shortcutText).cmuxFont(size: 11).tracking(0.5).lineLimit(1)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .fixedSize()
        }
    }

    /// Truncates rather than pushing the capsule past a narrow sidebar.
    private func title(_ text: String) -> some View {
        Text(text).cmuxFont(size: 12, weight: .medium).foregroundStyle(Color(nsColor: .labelColor)).lineLimit(1)
            .truncationMode(.tail)
    }

    /// First click asks to confirm; the second turns the setting off.
    private var closeButton: some View {
        Button {
            if isConfirmingHide {
                withAnimation(.easeOut(duration: 0.2)) {
                    isEnabled = false
                    isConfirmingHide = false
                }
            } else {
                withAnimation(.easeOut(duration: 0.15)) { isConfirmingHide = true }
            }
        } label: {
            CmuxSystemSymbolImage(systemName: "xmark", pointSize: 8, weight: .bold, tint: Color(nsColor: .secondaryLabelColor))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(isCloseHovered ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isCloseHovered = $0 }
        .safeHelp(String(localized: "sidebar.jumpToUnread.hide", defaultValue: "Hide Jump to Unread Button"))
        .accessibilityLabel(String(localized: "sidebar.jumpToUnread.hide", defaultValue: "Hide Jump to Unread Button"))
    }
}

private extension View {
    /// Liquid Glass on macOS 26 (a material capsule before), hairline rim,
    /// soft shadow, brighter on hover.
    func sidebarJumpToUnreadGlass(hovered: Bool) -> some View {
        Group {
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
        .overlay(Capsule().fill(Color.white.opacity(hovered ? 0.06 : 0)).allowsHitTesting(false))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.24), radius: 6, y: 2)
    }
}
