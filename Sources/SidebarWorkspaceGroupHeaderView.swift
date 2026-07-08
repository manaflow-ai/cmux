import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxSidebar
import SwiftUI
import CmuxSettings

/// Collapsible group header that doubles as the anchor workspace row.
struct SidebarWorkspaceGroupHeaderView: View, Equatable {
    // Closures and delegate factories are excluded because they are recreated
    // by the parent on each evaluation. The scalar snapshots below are the
    // header's render and behavior inputs under the LazyVStack.
    nonisolated static func == (lhs: SidebarWorkspaceGroupHeaderView, rhs: SidebarWorkspaceGroupHeaderView) -> Bool {
        lhs.groupId == rhs.groupId &&
            lhs.anchorWorkspaceId == rhs.anchorWorkspaceId &&
            lhs.name == rhs.name &&
            lhs.iconSymbol == rhs.iconSymbol &&
            lhs.tintHex == rhs.tintHex &&
            lhs.isCollapsed == rhs.isCollapsed &&
            lhs.isPinned == rhs.isPinned &&
            lhs.isAnchorActive == rhs.isAnchorActive &&
            lhs.memberCount == rhs.memberCount &&
            lhs.anchorUnreadCount == rhs.anchorUnreadCount &&
            lhs.canMarkRead == rhs.canMarkRead &&
            lhs.canMarkUnread == rhs.canMarkUnread &&
            lhs.hasLatestNotifications == rhs.hasLatestNotifications &&
            lhs.canMarkAllRead == rhs.canMarkAllRead &&
            lhs.canMarkAllUnread == rhs.canMarkAllUnread &&
            lhs.shortcutDigit == rhs.shortcutDigit &&
            lhs.shortcutModifierSymbol == rhs.shortcutModifierSymbol &&
            lhs.showsShortcutHint == rhs.showsShortcutHint &&
            lhs.shortcutHintXOffset == rhs.shortcutHintXOffset &&
            lhs.shortcutHintYOffset == rhs.shortcutHintYOffset &&
            lhs.fontScale == rhs.fontScale &&
            lhs.cwdContextMenuItems == rhs.cwdContextMenuItems &&
            lhs.newWorkspacePlacement == rhs.newWorkspacePlacement &&
            lhs.rowSpacing == rhs.rowSpacing &&
            lhs.isFirstRow == rhs.isFirstRow &&
            lhs.isBeingDragged == rhs.isBeingDragged &&
            lhs.topDropIndicatorVisible == rhs.topDropIndicatorVisible &&
            lhs.bottomDropIndicatorVisible == rhs.bottomDropIndicatorVisible
    }

    let groupId: UUID
    let anchorWorkspaceId: UUID
    let name: String
    let iconSymbol: String
    let tintHex: String?
    let isCollapsed: Bool
    let isPinned: Bool
    let isAnchorActive: Bool
    let memberCount: Int
    let anchorUnreadCount: Int
    let canMarkRead: Bool
    let canMarkUnread: Bool
    let hasLatestNotifications: Bool
    let canMarkAllRead: Bool
    let canMarkAllUnread: Bool
    let shortcutDigit: Int?
    let shortcutModifierSymbol: String?
    let showsShortcutHint: Bool
    let shortcutHintXOffset: Double
    let shortcutHintYOffset: Double
    let fontScale: CGFloat
    let cwdContextMenuItems: [CmuxResolvedConfigContextMenuItem]
    let newWorkspacePlacement: WorkspaceGroupNewPlacement?
    let rowSpacing: CGFloat
    let isFirstRow: Bool
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let bottomDropIndicatorVisible: Bool
    let onDragStart: () -> NSItemProvider
    let onToggleCollapsed: () -> Void
    let onFocusAnchor: () -> Void
    let onTapPlus: () -> Void
    let onRunResolvedItem: (CmuxResolvedConfigMenuAction) -> Void
    let onRename: () -> Void
    let onTogglePinned: () -> Void
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void
    let onClearLatestNotifications: () -> Void
    let onMarkAllRead: () -> Void
    let onMarkAllUnread: () -> Void
    let onUngroup: () -> Void
    let onDelete: () -> Void
    let onEditConfig: () -> Void
    let onOpenDocs: () -> Void

    @State private var rowInteractionState = SidebarWorkspaceRowInteractionState()

#if DEBUG
    // Plain-value environment probe set only by SidebarLazyLayoutScaleTests;
    // default no-op. See SidebarLazyContractProbe.
    @Environment(\.sidebarLazyContractProbe) private var sidebarLazyContractProbe
#endif

    private var metrics: SidebarWorkspaceGroupHeaderMetrics {
        SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale)
    }

    private var iconColor: Color {
        if let tintHex, let nsColor = NSColor(hex: tintHex) {
            return Color(nsColor: nsColor)
        }
        return .secondary
    }

    private var displayedIconSymbol: String {
        RenderableSystemSymbol.resolvedWorkspaceGroupIcon(explicit: iconSymbol, configured: nil)
    }

    private var shortcutHintPillText: String? {
        guard showsShortcutHint,
              let shortcutDigit,
              let shortcutModifierSymbol else { return nil }
        return "\(shortcutModifierSymbol)\(shortcutDigit)"
    }

    private var pinnedGroupTooltip: String {
        String(localized: "workspaceGroup.pinned.tooltip", defaultValue: "Pinned group")
    }

    var body: some View {
#if DEBUG
        let _ = { sidebarLazyContractProbe.groupHeaderRowBody?() }()
#endif
        HStack(spacing: 4) {
            if isPinned {
                CmuxSystemSymbolImage(
                    magnified: "pin.fill",
                    pointSize: metrics.pinnedIconFontSize,
                    weight: .semibold
                )
                .foregroundStyle(Color.secondary.opacity(0.8))
                .frame(width: metrics.iconFrame, height: metrics.iconFrame)
                .safeHelp(pinnedGroupTooltip)
                .accessibilityLabel(Text(pinnedGroupTooltip))
            }
            CmuxSystemSymbolImage(
                systemName: isCollapsed ? "chevron.right" : "chevron.down",
                pointSize: metrics.chevronFontSize,
                weight: .semibold,
                appliesGlobalFontMagnification: true
            )
                .foregroundStyle(.secondary)
                .frame(width: metrics.chevronFrame, height: metrics.chevronFrame)
                .contentShape(Rectangle())
                .onTapGesture { onToggleCollapsed() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(
                    Text(
                        isCollapsed
                            ? String(localized: "workspaceGroup.expand.a11y", defaultValue: "Expand group")
                            : String(localized: "workspaceGroup.collapse.a11y", defaultValue: "Collapse group")
                    )
                )

            HStack(spacing: 6) {
                CmuxSystemSymbolImage(
                    systemName: displayedIconSymbol,
                    pointSize: metrics.iconFontSize,
                    weight: .semibold,
                    appliesGlobalFontMagnification: true
                )
                    .foregroundStyle(iconColor)
                    .frame(width: metrics.iconFrame, height: metrics.iconFrame)
                    .accessibilityHidden(true)
                Text(name)
                    .cmuxFont(size: metrics.nameFontSize, weight: .semibold)
                    .foregroundStyle(isAnchorActive ? Color.primary : Color.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if anchorUnreadCount > 0 {
                    Text("\(anchorUnreadCount)")
                        .cmuxFont(size: metrics.unreadFontSize, weight: .semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, metrics.unreadHorizontalPadding)
                        .padding(.vertical, metrics.unreadVerticalPadding)
                        .background(Capsule().fill(Color.accentColor))
                        .accessibilityLabel(Text(String.localizedStringWithFormat(
                            String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"),
                            anchorUnreadCount
                        )))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onFocusAnchor() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(name))
            .accessibilityHint(Text(String(
                localized: "workspaceGroup.focusAnchor.a11y",
                defaultValue: "Focus the group's anchor workspace"
            )))

            let plusVisible = rowInteractionState.shouldShowCloseButton(
                canCloseWorkspace: true,
                shortcutHintModeActive: showsShortcutHint
            )
            Button(action: onTapPlus) {
                CmuxSystemSymbolImage(
                    systemName: "plus",
                    pointSize: metrics.plusFontSize,
                    weight: .medium,
                    appliesGlobalFontMagnification: true
                )
                    .foregroundStyle(.secondary)
                    .frame(width: metrics.plusFrame, height: metrics.plusFrame)
                    .contentShape(Rectangle())
                    .opacity(plusVisible ? 1 : 0)
            }
            .buttonStyle(.plain)
            .frame(width: metrics.plusFrame, height: metrics.plusFrame)
            .allowsHitTesting(plusVisible)
            .accessibilityHidden(!plusVisible)
            .accessibilityLabel(Text(String(
                localized: "workspaceGroup.newWorkspaceInGroup.a11y",
                defaultValue: "New workspace in group"
            )))
            .contextMenu {
                Button(
                    String(
                        localized: "workspaceGroup.plus.contextMenu.newWorkspace",
                        defaultValue: "New Workspace in Group"
                    ),
                    action: onTapPlus
                )
                .onAppear {
                    rowInteractionState.contextMenuDidAppear()
                }
                .onDisappear {
                    rowInteractionState.contextMenuDidDisappear()
                }
                if !cwdContextMenuItems.isEmpty {
                    Divider()
                    ForEach(cwdContextMenuItems) { item in
                        switch item {
                        case .separator:
                            Divider()
                        case .action(let action):
                            Button(action.title) {
                                onRunResolvedItem(action)
                            }
                        }
                    }
                }
                Divider()
                Button(
                    String(
                        localized: "workspaceGroup.plus.contextMenu.editConfig",
                        defaultValue: "Edit Group Config..."
                    ),
                    action: onEditConfig
                )
                Button(
                    String(
                        localized: "workspaceGroup.plus.contextMenu.openDocs",
                        defaultValue: "Open Workspace Groups Docs"
                    ),
                    action: onOpenDocs
                )
            }
        }
        .padding(.vertical, 5)
        .padding(.trailing, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
        .contentShape(Rectangle())
        .background(
            isAnchorActive
                ? Color.primary.opacity(0.08)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .sidebarShortcutHintOverlay(
            text: shortcutHintPillText,
            emphasis: isAnchorActive ? 1.0 : 0.9,
            offsetX: shortcutHintXOffset,
            offsetY: shortcutHintYOffset
        )
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
        .onHover { hovering in
            rowInteractionState.setPointerHovering(hovering)
        }
        .opacity(isBeingDragged ? 0.6 : 1)
        .overlay(alignment: .top) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: topDropIndicatorVisible,
                isFirstRow: isFirstRow,
                rowSpacing: rowSpacing
            )
        }
        .overlay(alignment: .bottom) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: bottomDropIndicatorVisible,
                isFirstRow: false,
                rowSpacing: rowSpacing,
                isBottomEdge: true,
                leadingInset: metrics.groupScopedBottomDropIndicatorLeadingInset
            )
        }
        .onDrag(onDragStart)
        .internalOnlyTabDrag()
        .overlay {
            if rowInteractionState.contextMenuVisible {
                SidebarWorkspaceRowMenuTrackingReconciler { pointerInsideRow in
                    rowInteractionState.contextMenuTrackingDidEnd(pointerInsideRow: pointerInsideRow)
                }
                .onAppear {
                    rowInteractionState.contextMenuTrackingObserverDidInstall()
                }
            }
        }
        .onDisappear {
            rowInteractionState.setPointerHovering(false)
        }
        .contextMenu {
            Button(
                String(
                    localized: "workspaceGroup.plus.contextMenu.newWorkspace",
                    defaultValue: "New Workspace in Group"
                ),
                action: onTapPlus
            )
            .onAppear {
                rowInteractionState.contextMenuDidAppear()
            }
            .onDisappear {
                rowInteractionState.contextMenuDidDisappear()
            }
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.rename",
                    defaultValue: "Rename Group..."
                ),
                action: onRename
            )
            Button(
                isPinned
                    ? String(
                        localized: "workspaceGroup.contextMenu.unpin",
                        defaultValue: "Unpin Group"
                    )
                    : String(
                        localized: "workspaceGroup.contextMenu.pin",
                        defaultValue: "Pin Group"
                    ),
                action: onTogglePinned
            )
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.markRead",
                    defaultValue: "Mark Group as Read"
                ),
                action: onMarkRead
            )
            .disabled(!canMarkRead)
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.markUnread",
                    defaultValue: "Mark Group as Unread"
                ),
                action: onMarkUnread
            )
            .disabled(!canMarkUnread)
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.clearLatestNotifications",
                    defaultValue: "Clear Latest Notifications"
                ),
                action: onClearLatestNotifications
            )
            .disabled(!hasLatestNotifications)
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.markAllRead",
                    defaultValue: "Mark All Workspaces in Group as Read"
                ),
                action: onMarkAllRead
            )
            .disabled(!canMarkAllRead)
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.markAllUnread",
                    defaultValue: "Mark All Workspaces in Group as Unread"
                ),
                action: onMarkAllUnread
            )
            .disabled(!canMarkAllUnread)
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.editConfig",
                    defaultValue: "Edit Group Config..."
                ),
                action: onEditConfig
            )
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.openDocs",
                    defaultValue: "Open Workspace Groups Docs"
                ),
                action: onOpenDocs
            )
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.ungroup",
                    defaultValue: "Ungroup Workspaces"
                ),
                action: onUngroup
            )
            Button(
                role: .destructive,
                action: onDelete
            ) {
                Text(
                    String(
                        localized: "workspaceGroup.contextMenu.delete",
                        defaultValue: "Delete Group"
                    )
                )
            }
        }
    }
}
