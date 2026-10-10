import AppKit
import Combine
import SwiftUI

/// What the sidebar footer's Jump to Unread control shows for a given unread
/// count and configured shortcut. Kept separate from the view so the label,
/// tooltip and visibility rules are testable without hosting SwiftUI.
struct SidebarJumpToUnreadButtonPresentation: Equatable {
    /// A turn arrow reads as "go there"; straight down arrows read as download.
    static let systemName = "arrow.turn.down.right"
    static let maxShownCount = 99

    let label: String
    let helpText: String
    /// The badge text, nil when nothing is unread (the control is hidden then).
    let countText: String?
    /// The configured shortcut, always shown to teach it; nil when unbound.
    let shortcutText: String?

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
                : nil,
            shortcutText: shortcut.isUnbound ? nil : shortcut.displayString
        )
    }
}

extension View {
    /// Puts the Jump to Unread control at the trailing end of the footer row.
    func sidebarJumpToUnreadBar(presentationMode: WorkspacePresentationModeSettings.Mode) -> some View {
        HStack(spacing: 4) {
            frame(maxWidth: .infinity, alignment: .leading)
            SidebarJumpToUnreadButton(presentationMode: presentationMode)
        }
    }
}

/// The on-screen ⇧⌘U at the trailing end of the sidebar footer, shown only
/// while something is unread: the unread count, the configured shortcut (to
/// teach it) and a × that hides it for good. The jump runs
/// `AppDelegate.jumpToLatestUnread()`, the same path as the Notifications menu
/// item, the command palette and the shortcut.
///
/// Unread state is observed here rather than in `SidebarFooterButtons`: the
/// store's menu snapshot is reduced to a deduplicated unread count, so
/// notification churn re-renders only this view, and only when the count
/// changes.
struct SidebarJumpToUnreadButton: View {
    /// Design variations under review; `a` ships. Debug builds switch them
    /// from the control's context menu.
    enum Style: String, CaseIterable {
        /// Bordered button: count, arrow, shortcut, × inline.
        case a
        /// Bordered button: count and shortcut, × on the corner on hover.
        case n
        /// Plain text count and shortcut (not clickable), × always inline.
        case p
    }

    static let hiddenDefaultsKey = "sidebar.jumpToUnreadButton.hidden"
    static let styleDefaultsKey = "debug.sidebarJumpToUnreadButton.style"

    @Environment(\.cmuxAccentColor) private var cmuxAccent

    let presentationMode: WorkspacePresentationModeSettings.Mode

    @State private var unreadCount: Int
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var isHovered = false
    @State private var showsHiddenNote = false
    @AppStorage(SidebarJumpToUnreadButton.hiddenDefaultsKey) private var isHiddenByUser = false
    @AppStorage(SidebarJumpToUnreadButton.styleDefaultsKey) private var styleRawValue = Style.a.rawValue

    init(presentationMode: WorkspacePresentationModeSettings.Mode) {
        self.presentationMode = presentationMode
        _unreadCount = State(
            initialValue: TerminalNotificationStore.shared.notificationMenuSnapshot.unreadCount
        )
    }

    private var style: Style {
#if DEBUG
        Style(rawValue: styleRawValue) ?? .a
#else
        .a
#endif
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
               resolved.isVisible, !isHiddenByUser {
                control(resolved)
                    .onHover { isHovered = $0 }
                    .contextMenu { contextMenuItems }
            } else {
                Color.clear.frame(width: 0, height: 22)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsHiddenNote {
                Text(String(
                    localized: "sidebar.jumpToUnread.hiddenNote",
                    defaultValue: "Hidden. Turn it back on in Settings > Sidebar."
                ))
                .cmuxFont(size: 11)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .fixedSize()
                .offset(y: -28)
                .transition(.opacity)
            }
        }
        .task(id: showsHiddenNote) {
            guard showsHiddenNote else { return }
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut(duration: 0.2)) { showsHiddenNote = false }
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

    @ViewBuilder
    private func control(_ resolved: SidebarJumpToUnreadButtonPresentation) -> some View {
        switch style {
        case .a:
            jumpButton(resolved) {
                HStack(spacing: 5) {
                    badge(resolved)
                    CmuxSystemSymbolImage(
                        systemName: SidebarJumpToUnreadButtonPresentation.systemName,
                        pointSize: 11,
                        weight: .semibold,
                        tint: cmuxAccent.color
                    )
                    shortcut(resolved)
                    closeButton(corner: false)
                }
                .padding(.leading, 3)
                .padding(.trailing, 4)
            }
        case .n:
            jumpButton(resolved) {
                HStack(spacing: 5) {
                    badge(resolved)
                    shortcut(resolved)
                }
                .padding(.leading, 3)
                .padding(.trailing, 8)
            }
            .overlay(alignment: .topTrailing) {
                closeButton(corner: true)
                    .offset(x: 6, y: -6)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                    .animation(.easeOut(duration: 0.15), value: isHovered)
            }
        case .p:
            HStack(spacing: 6) {
                if let countText = resolved.countText {
                    Text(countText)
                        .cmuxFont(size: 12, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(cmuxAccent.color)
                }
                shortcut(resolved)
                closeButton(corner: false)
            }
            .padding(.leading, 7)
            .padding(.trailing, 2)
            .frame(height: 22)
            .fixedSize()
            .safeHelp(resolved.helpText)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(resolved.label)
            .accessibilityValue(resolved.countText ?? "")
            .accessibilityIdentifier("SidebarJumpToUnreadButton")
        }
    }

    private func jumpButton(
        _ resolved: SidebarJumpToUnreadButtonPresentation,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button {
            AppDelegate.shared?.jumpToLatestUnread()
        } label: {
            label()
                .frame(height: 22)
                .contentShape(Capsule())
        }
        .buttonStyle(SidebarJumpToUnreadGlassButtonStyle())
        .fixedSize()
        .safeHelp(resolved.helpText)
        .accessibilityLabel(resolved.label)
        .accessibilityValue(resolved.countText ?? "")
        .accessibilityIdentifier("SidebarJumpToUnreadButton")
    }

    @ViewBuilder
    private func badge(_ resolved: SidebarJumpToUnreadButtonPresentation) -> some View {
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

    @ViewBuilder
    private func shortcut(_ resolved: SidebarJumpToUnreadButtonPresentation) -> some View {
        if let shortcutText = resolved.shortcutText {
            Text(shortcutText)
                .cmuxFont(size: 11)
                .tracking(0.5)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
        }
    }

    /// Hides the control for good; Settings > Sidebar brings it back.
    private func closeButton(corner: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                isHiddenByUser = true
                showsHiddenNote = true
            }
        } label: {
            CmuxSystemSymbolImage(
                systemName: "xmark",
                pointSize: corner ? 7 : 8,
                weight: .bold,
                tint: Color(nsColor: corner ? .secondaryLabelColor : .tertiaryLabelColor)
            )
            .frame(width: corner ? 15 : 14, height: corner ? 15 : 14)
            .contentShape(Circle())
        }
        .buttonStyle(SidebarJumpToUnreadGlassButtonStyle(isCloseButton: true, isCorner: corner))
        .safeHelp(String(localized: "sidebar.jumpToUnread.hide", defaultValue: "Hide Jump to Unread Button"))
        .accessibilityLabel(String(localized: "sidebar.jumpToUnread.hide", defaultValue: "Hide Jump to Unread Button"))
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(String(localized: "sidebar.jumpToUnread.hide", defaultValue: "Hide Jump to Unread Button")) {
            isHiddenByUser = true
            showsHiddenNote = true
        }
#if DEBUG
        Divider()
        ForEach(Style.allCases, id: \.self) { candidate in
            Button("Debug: Style \(candidate.rawValue.uppercased())") { styleRawValue = candidate.rawValue }
        }
#endif
    }
}

/// The jump control's bordered capsule (fill, hairline rim, small shadow;
/// stronger fill on hover and press), and the × buttons: inline ones are a
/// circle that fills on hover, the corner one is a solid badge.
private struct SidebarJumpToUnreadGlassButtonStyle: ButtonStyle {
    var isCloseButton = false
    var isCorner = false

    func makeBody(configuration: Configuration) -> some View {
        SidebarJumpToUnreadGlassButtonBody(configuration: configuration, isCloseButton: isCloseButton, isCorner: isCorner)
    }
}

private struct SidebarJumpToUnreadGlassButtonBody: View {
    let configuration: SidebarJumpToUnreadGlassButtonStyle.Configuration
    let isCloseButton: Bool
    let isCorner: Bool
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isCloseButton {
            configuration.label
                .sidebarJumpToUnreadGlass(closeButton: true, corner: isCorner, hovered: isHovered, pressed: configuration.isPressed, dark: colorScheme == .dark)
                .onHover { isHovered = $0 }
        } else {
            configuration.label
                .sidebarJumpToUnreadGlass(closeButton: false, corner: false, hovered: isHovered, pressed: configuration.isPressed, dark: colorScheme == .dark)
                .onHover { isHovered = $0 }
        }
    }
}

private extension View {
    func sidebarJumpToUnreadGlass(closeButton: Bool, corner: Bool, hovered: Bool, pressed: Bool, dark: Bool) -> some View {
        Group {
            if !closeButton {
                background(Capsule().fill(Color.primary.opacity(pressed ? 0.18 : hovered ? 0.12 : 0.07)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(0.18), radius: 1, y: 1)
            } else if corner {
                background(Circle().fill(dark ? Color(white: 0.28) : Color(white: 0.95)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(0.3), radius: 1.5, y: 1)
                    .brightness(hovered ? 0.06 : 0)
            } else {
                background(Circle().fill(Color.primary.opacity(pressed ? 0.2 : hovered ? 0.14 : 0)))
            }
        }
    }
}
