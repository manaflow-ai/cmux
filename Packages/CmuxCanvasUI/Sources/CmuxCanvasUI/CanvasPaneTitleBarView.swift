import SwiftUI

/// The SwiftUI chrome strip at the top of a canvas pane: its tabs and a
/// close button. With one tab it reads as a plain title bar; with several it
/// becomes a tab strip. The strip is also the pane's move-drag handle (drag
/// handling lives in `CanvasPaneView`; tab buttons consume their own clicks,
/// the surrounding strip does not). All text arrives pre-localized through
/// ``CanvasPaneChrome``.
struct CanvasPaneTitleBarView: View {
    let chrome: CanvasPaneChrome
    let onSelectTab: (UUID) -> Void
    let onCloseTab: (UUID) -> Void
    /// Pane-drag relay for drags that start on a tab pill (pills consume
    /// mouse-down, so the AppKit title-bar drag path never sees them).
    /// Translation is in pane-local points, which equals document points at
    /// any magnification because the strip renders inside the scaled space.
    let onTabStripDrag: (CGSize) -> Void
    let onTabStripDragEnded: () -> Void

    static let height: CGFloat = 28

    var body: some View {
        HStack(spacing: 2) {
            if chrome.tabs.count == 1, let tab = chrome.tabs.first {
                singleTitle(tab)
            } else {
                ForEach(chrome.tabs) { tab in
                    CanvasPaneTabButton(
                        tab: tab,
                        isSelected: tab.id == chrome.selectedTabId,
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
            }
            Spacer(minLength: 4)
            if chrome.tabs.count == 1, let tab = chrome.tabs.first {
                CanvasPaneCloseButton(label: chrome.closeActionLabel) {
                    onCloseTab(tab.id)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .contentShape(Rectangle())
    }

    private func singleTitle(_ tab: CanvasTabChrome) -> some View {
        HStack(spacing: 6) {
            if let iconSystemName = tab.iconSystemName {
                Image(systemName: iconSystemName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(chrome.isFocused ? .primary : .secondary)
            }
            Text(tab.title)
                .font(.system(size: 12, weight: chrome.isFocused ? .semibold : .regular))
                .foregroundStyle(chrome.isFocused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, 2)
    }
}

/// One tab in a multi-tab pane strip.
private struct CanvasPaneTabButton: View {
    let tab: CanvasTabChrome
    let isSelected: Bool
    let paneIsFocused: Bool
    let closeActionLabel: String
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 4) {
                if let iconSystemName = tab.iconSystemName {
                    Image(systemName: iconSystemName)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(tab.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140)
                if isHovering {
                    CanvasPaneCloseButton(label: closeActionLabel, size: 14, onClose: onClose)
                }
            }
            .foregroundStyle(selectedForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.12) : (isHovering ? Color.primary.opacity(0.06) : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectedForeground: HierarchicalShapeStyle {
        if isSelected {
            return paneIsFocused ? .primary : .secondary
        }
        return .tertiary
    }
}

/// The shared hover-circle close button used by the strip.
private struct CanvasPaneCloseButton: View {
    let label: String
    var size: CGFloat = 18
    let onClose: () -> Void

    @State private var isHovering = false

    init(label: String, size: CGFloat = 18, onClose: @escaping () -> Void) {
        self.label = label
        self.size = size
        self.onClose = onClose
    }

    var body: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: size / 2, weight: .bold))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(isHovering ? Color.primary.opacity(0.12) : .clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
