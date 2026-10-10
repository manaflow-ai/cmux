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

    static func resolve(unreadCount: Int, shortcut: StoredShortcut) -> SidebarJumpToUnreadButtonPresentation {
        let action = KeyboardShortcutSettings.Action.jumpToUnread
        let title = action.label
        return SidebarJumpToUnreadButtonPresentation(
            label: String(localized: "sidebar.jumpToUnread.button", defaultValue: "Jump to unread"),
            helpText: shortcut.isUnbound ? title : action.tooltip(title, shortcut: shortcut),
            countText: unreadCount > 0 ? (unreadCount > maxShownCount ? "\(maxShownCount)+" : "\(unreadCount)") : nil,
            shortcutText: shortcut.isUnbound ? nil : shortcut.displayString
        )
    }
}

extension View {
    /// Puts the Jump to Unread control on its own row above the footer row.
    func sidebarJumpToUnreadBar(presentationMode: WorkspacePresentationModeSettings.Mode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarJumpToUnreadButton(presentationMode: presentationMode, placement: .aboveFooter)
            HStack(spacing: 4) {
                frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 0, height: 22)
            }
        }
    }
}

/// The on-screen ⇧⌘U, shown only while something is unread. On hover the
/// count turns into the configured shortcut (to teach it) and a × follows;
/// one × click asks to confirm, a second hides it for good. The jump runs
/// `AppDelegate.jumpToLatestUnread()`, like the menu item and the shortcut.
/// Unread state is reduced to a deduplicated count here, so notification
/// churn re-renders only this view, and only when the count changes.
struct SidebarJumpToUnreadButton: View {
    /// Design variations under review; `sCentered` ships. Debug builds switch them
    /// from the control's context menu.
    enum Style: String, CaseIterable {
        /// Glass capsule centered on its own row above the sidebar footer.
        case sCentered
        /// The same, compact: "↳ (3)" at rest, the label only on hover.
        case sCompact
        /// The same capsule at the bottom center of the window, hosted in
        /// AppKit above the terminal portal (see `WindowOverlay`).
        case windowBottom

        var placement: Placement { self == .windowBottom ? .windowBottom : .aboveFooter }
        var debugTitle: String {
            switch self {
            case .sCentered: return "Debug: Style Sidebar Bottom Center"
            case .sCompact: return "Debug: Style Sidebar Compact"
            case .windowBottom: return "Debug: Style Window Bottom Center"
            }
        }
    }

    /// Where an instance sits; each renders only the styles placed there.
    enum Placement { case aboveFooter, windowBottom }

    /// Mounts the window style from the main content area.
    static func windowBottom(isMinimalMode: Bool) -> WindowBottomInstaller { WindowBottomInstaller(isMinimalMode: isMinimalMode) }

    static let hiddenDefaultsKey = "sidebar.jumpToUnreadButton.hidden"
    static let styleDefaultsKey = "debug.sidebarJumpToUnreadButton.style"

    @Environment(\.cmuxAccentColor) private var cmuxAccent
    let presentationMode: WorkspacePresentationModeSettings.Mode
    let placement: Placement
    @State private var unreadCount: Int
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var isHovered = false
    @State private var isCloseHovered = false
    /// After the first × click the capsule asks for a second one.
    @State private var isConfirmingHide = false
    @State private var showsHiddenNote = false
    @AppStorage(SidebarJumpToUnreadButton.hiddenDefaultsKey) private var isHiddenByUser = false
    @AppStorage(SidebarJumpToUnreadButton.styleDefaultsKey) private var styleRawValue = Style.sCentered.rawValue

    init(presentationMode: WorkspacePresentationModeSettings.Mode, placement: Placement) {
        self.presentationMode = presentationMode
        self.placement = placement
        _unreadCount = State(initialValue: TerminalNotificationStore.shared.notificationMenuSnapshot.unreadCount)
    }

    private var style: Style {
#if DEBUG
        Style(rawValue: styleRawValue) ?? .sCentered
#else
        .sCentered
#endif
    }

    private var presentation: SidebarJumpToUnreadButtonPresentation {
        let _ = keyboardShortcutSettingsObserver.revision
        return .resolve(unreadCount: unreadCount, shortcut: KeyboardShortcutSettings.shortcut(for: .jumpToUnread))
    }

    var body: some View {
        let resolved = presentation
        Group {
            if SidebarFooterPresentationPolicy.isVisible(.jumpToUnread, presentationMode: presentationMode),
               resolved.isVisible, !isHiddenByUser, style.placement == placement {
                control(resolved)
                    .contextMenu { contextMenuItems }
                    .frame(maxWidth: placement == .aboveFooter ? .infinity : nil, alignment: .center)
                    .padding(.bottom, placement == .aboveFooter ? 8 : 0)
            } else if placement == .windowBottom, showsHiddenNote {
                // The window capsule stays up with the note in it, then goes.
                hiddenNote.padding(.horizontal, 12).frame(height: 28).sidebarJumpToUnreadFloatingGlass(hovered: false, drawsGlass: true)
            } else {
                // Zero size also tells `WindowOverlay` to hide the capsule.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .overlay(alignment: .bottom) {
            if showsHiddenNote, placement == .aboveFooter {
                hiddenNote.offset(y: -8).transition(.opacity)
            }
        }
        .task(id: showsHiddenNote) {
            guard showsHiddenNote else { return }
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut(duration: 0.2)) { showsHiddenNote = false }
        }
        .task(id: isConfirmingHide) {
            guard isConfirmingHide else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { isConfirmingHide = false }
        }
        .onReceive(TerminalNotificationStore.shared.$notificationMenuSnapshot.map(\.unreadCount).removeDuplicates()) { count in
            if unreadCount != count { unreadCount = count }
        }
    }

    /// At rest "↳ Jump to Unread (3)"; on hover "↳ Jump to Unread ⇧⌘U ×";
    /// after one × click "Click × again to not show again ×".
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
                        title(String(localized: "sidebar.jumpToUnread.confirmHide", defaultValue: "Click × again to not show again"))
                    } else {
                        let arrow = SidebarJumpToUnreadButtonPresentation.systemName
                        CmuxSystemSymbolImage(systemName: arrow, pointSize: 11, weight: .semibold, tint: cmuxAccent.color)
                        if style != .sCompact {
                            title(String(localized: "sidebar.jumpToUnread.title", defaultValue: "Last unread"))
                        } else if isHovered {
                            title(String(localized: "sidebar.jumpToUnread.compactTitle", defaultValue: "Jump to Unread"))
                                .transition(.opacity.animation(.easeOut(duration: 0.12).delay(0.08)))
                        }
                        // Hovering swaps the count for the key that does the same thing.
                        if isHovered, let shortcutText = resolved.shortcutText {
                            Text(shortcutText).cmuxFont(size: 11).tracking(0.5).lineLimit(1)
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        } else if let countText = resolved.countText {
                            Text(countText).cmuxFont(size: 9, weight: .semibold).monospacedDigit().foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Capsule().fill(cmuxAccent.color))
                            // Compact keeps the key on screen at rest too: "↳ (3) ⇧⌘U".
                            if style == .sCompact, let shortcutText = resolved.shortcutText {
                                Text(shortcutText).cmuxFont(size: 11).tracking(0.5).lineLimit(1)
                                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            }
                        }
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
        .fixedSize()
        .sidebarJumpToUnreadFloatingGlass(hovered: isHovered, drawsGlass: true)
        .onHover { hovering in
            isHovered = hovering
            if !hovering { isConfirmingHide = false }
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isConfirmingHide)
    }

    private func title(_ text: String) -> some View {
        Text(text).cmuxFont(size: 12, weight: .medium).foregroundStyle(Color(nsColor: .labelColor)).lineLimit(1)
    }

    /// First click asks to confirm; the second hides the control for good
    /// (Settings > Sidebar brings it back).
    private var closeButton: some View {
        Button {
            if isConfirmingHide {
                withAnimation(.easeOut(duration: 0.2)) {
                    isHiddenByUser = true
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
        .onHover { isCloseHovered = $0 }
        .safeHelp(String(localized: "sidebar.jumpToUnread.hide", defaultValue: "Hide Jump to Unread Button"))
        .accessibilityLabel(String(localized: "sidebar.jumpToUnread.hide", defaultValue: "Hide Jump to Unread Button"))
    }

    private var hiddenNote: some View {
        Text(String(localized: "sidebar.jumpToUnread.hiddenNote", defaultValue: "Hidden. Turn it back on in Settings > Sidebar."))
            .cmuxFont(size: 11).foregroundStyle(Color(nsColor: .secondaryLabelColor)).fixedSize()
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(String(localized: "sidebar.jumpToUnread.hide", defaultValue: "Hide Jump to Unread Button")) {
            isHiddenByUser = true
        }
#if DEBUG
        Divider()
        ForEach(Style.allCases, id: \.self) { candidate in
            Button(candidate.debugTitle) { styleRawValue = candidate.rawValue }
        }
#endif
    }
}

extension SidebarJumpToUnreadButton {
    /// The window style's mount point: hosts the capsule in its window's AppKit
    /// overlay layer while that style is selected. SwiftUI sits under the
    /// terminal portal, so terminals would draw over it, keep their I-beam
    /// and stay out of its glass.
    struct WindowBottomInstaller: NSViewRepresentable {
        let isMinimalMode: Bool
        @AppStorage(SidebarJumpToUnreadButton.styleDefaultsKey) private var styleRawValue = Style.sCentered.rawValue

        func makeNSView(context: Context) -> WindowAnchor { WindowAnchor() }

        func updateNSView(_ anchor: WindowAnchor, context: Context) {
#if DEBUG
            let isSelected = Style(rawValue: styleRawValue) == .windowBottom
#else
            let isSelected = false
#endif
            let mode: WorkspacePresentationModeSettings.Mode = isMinimalMode ? .minimal : .standard
            anchor.content = isSelected ? SidebarJumpToUnreadButton(presentationMode: mode, placement: .windowBottom) : nil
        }

        static func dismantleNSView(_ anchor: WindowAnchor, coordinator: ()) { anchor.content = nil }
    }

    final class WindowAnchor: NSView {
        var content: SidebarJumpToUnreadButton? { didSet { synchronize() } }
        private weak var overlay: WindowOverlay?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            synchronize()
        }

        private func synchronize() {
            let next = content == nil ? nil : window.map { WindowOverlay.controller(for: $0) }
            if overlay !== next { overlay?.remove() }
            overlay = next
            if let content { next?.show(content) }
        }
    }
}

private extension View {
    /// Liquid Glass on macOS 26 (a material capsule before), hairline rim,
    /// soft shadow, brighter on hover. The window style's capsule sits in an
    /// AppKit host above the terminals, so its glass samples them too.
    @ViewBuilder
    func sidebarJumpToUnreadFloatingGlass(hovered: Bool, drawsGlass: Bool) -> some View {
        let hoverFill = Capsule().fill(Color.white.opacity(hovered ? 0.06 : 0)).allowsHitTesting(false)
        if drawsGlass {
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
            .overlay(hoverFill)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.24), radius: 6, y: 2)
        } else {
            overlay(hoverFill)
        }
    }
}
