import SwiftUI

/// The tab bar at the top of a canvas pane, mirroring the workspace split
/// pane tab bar's anatomy (30pt bar, full-height square tabs, right-edge
/// separators, selected/hover fills, 14pt icon slot that becomes a close
/// button on hover, 11pt centered titles). The bar is also the pane's
/// move-drag handle: empty bar area drags via the AppKit path, and tabs
/// relay drags through `onTabStripDrag`. All text arrives pre-localized
/// through ``CanvasPaneChrome``.
struct CanvasPaneTitleBarView: View {
    let chrome: CanvasPaneChrome
    let onSelectTab: (UUID) -> Void
    let onCloseTab: (UUID) -> Void
    /// Pane-drag relay for drags that start on a tab (tabs consume
    /// mouse-down, so the AppKit title-bar drag path never sees them).
    /// Translation is in pane-local points, which equals document points at
    /// any magnification because the strip renders inside the scaled space.
    let onTabStripDrag: (CGSize) -> Void
    let onTabStripDragEnded: () -> Void

    /// Matches the split pane tab bar height.
    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            ForEach(chrome.tabs) { tab in
                CanvasPaneTabItem(
                    tab: tab,
                    isSelected: chrome.tabs.count == 1 || tab.id == chrome.selectedTabId,
                    paneIsFocused: chrome.isFocused,
                    closeActionLabel: chrome.closeActionLabel,
                    onSelect: { onSelectTab(tab.id) },
                    onClose: { onCloseTab(tab.id) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { onTabStripDrag($0.translation) }
                        .onEnded { _ in onTabStripDragEnded() }
                )
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.height)
        .contentShape(Rectangle())
    }
}

/// One tab, visually matching the workspace split pane tabs: full-height
/// rectangle, selected/hover background fill, a 1px trailing separator, and
/// an icon slot that swaps to a close button on hover.
private struct CanvasPaneTabItem: View {
    let tab: CanvasTabChrome
    let isSelected: Bool
    let paneIsFocused: Bool
    let closeActionLabel: String
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false

    private var textOpacity: Double {
        isSelected && paneIsFocused ? 0.82 : 0.62
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                iconOrClose
                Text(tab.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(textOpacity))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: 220, minHeight: CanvasPaneTitleBarView.height, maxHeight: CanvasPaneTitleBarView.height)
            .background(tabBackground)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var iconOrClose: some View {
        ZStack {
            if isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.primary.opacity(isCloseHovered ? 0.82 : 0.62))
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isCloseHovered ? Color.primary.opacity(0.12) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { isCloseHovered = $0 }
                .help(closeActionLabel)
                .accessibilityLabel(closeActionLabel)
            } else if let iconSystemName = tab.iconSystemName {
                Image(systemName: iconSystemName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(textOpacity))
            }
        }
        .frame(width: 14, height: 14)
    }

    private var tabBackground: some View {
        ZStack {
            if isSelected {
                Rectangle().fill(Color.primary.opacity(0.10))
            } else if isHovered {
                Rectangle().fill(Color.primary.opacity(0.05))
            } else {
                Color.clear
            }
            HStack {
                Spacer()
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }
        }
    }
}
