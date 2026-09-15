import CmuxFoundation
import SwiftUI

/// Hit rects for one rendered tab, in the tab bar's local coordinates.
/// Read from the rendered AppKit witnesses when routing each mouse event.
struct CanvasTabHitRegions: Equatable {
    var tabFrames: [UUID: CGRect] = [:]
    var closeFrames: [UUID: CGRect] = [:]
}

/// The tab bar at the top of a canvas pane, mirroring the workspace split
/// pane tab bar's anatomy (30pt bar, full-height square tabs, right-edge
/// separators, selected/hover fills, icon slot that becomes a close glyph on
/// hover, 11pt centered titles). Render-only: all clicks and drags are
/// handled by `CanvasPaneView` via the reported hit regions, and horizontal
/// overflow scrolling is driven by `CanvasPaneView` feeding `scrollOffset`
/// (a SwiftUI ScrollView can't be used because the pane view claims the
/// title-bar region's mouse events for drag/click routing).
struct CanvasPaneTitleBarView: View {
    let chrome: CanvasPaneChrome
    /// Tab bar background, for deriving bonsplit-style active/hover fills.
    let barBackground: NSColor
    /// The tab currently under the AppKit pointer in tab-bar coordinates.
    let hoveredTabId: UUID?
    /// Horizontal scroll offset in points (>= 0 scrolls tabs left), clamped
    /// by the pane view against the reported content width.
    let scrollOffset: CGFloat
    let geometryRegistry: CanvasTabGeometryRegistry
    let onContentWidthChanged: (CGFloat) -> Void

    /// Matches the split pane tab bar height.
    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            ForEach(chrome.tabs) { tab in
                CanvasPaneTabItem(
                    tab: tab,
                    isSelected: chrome.tabs.count == 1 || tab.id == chrome.selectedTabId,
                    isHovered: tab.id == hoveredTabId,
                    paneIsFocused: chrome.isFocused,
                    barBackground: barBackground,
                    geometryRegistry: geometryRegistry
                )
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            onContentWidthChanged(width)
        }
        .fixedSize(horizontal: true, vertical: false)
        .offset(x: -scrollOffset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .clipped()
    }
}

/// One tab, visually matching the workspace split pane tabs: full-height
/// rectangle, selected/hover background fill, a 1px trailing separator, and
/// an icon slot that swaps to a close glyph on hover.
private struct CanvasPaneTabItem: View {
    let tab: CanvasTabChrome
    let isSelected: Bool
    let isHovered: Bool
    let paneIsFocused: Bool
    /// The tab bar background, used to derive bonsplit-style active/hover
    /// fills (lighten on dark themes, darken on light).
    let barBackground: NSColor
    let geometryRegistry: CanvasTabGeometryRegistry

    private var textColor: Color {
        Color(nsColor: isSelected && paneIsFocused ? .labelColor : .secondaryLabelColor)
    }

    var body: some View {
        HStack(spacing: 6) {
            iconOrClose
            Text(tab.title)
                .cmuxFont(size: 11)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: 220, minHeight: CanvasPaneTitleBarView.height, maxHeight: CanvasPaneTitleBarView.height)
        .background(tabBackground)
        .background(CanvasTabHitRegionView(tabId: tab.id, kind: .tab, registry: geometryRegistry))
        .overlay(alignment: .trailing) {
            if let hint = tab.shortcutHint {
                Text(verbatim: hint)
                    .cmuxFont(size: 9, weight: .semibold)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
                    .padding(.trailing, 5)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("canvas.tab.shortcutHint.\(tab.id.uuidString)")
            }
        }
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var iconOrClose: some View {
        ZStack {
            if isHovered {
                Image(systemName: "xmark")
                    .cmuxFont(size: 9, weight: .bold)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .frame(width: 16, height: 16)
            } else if let iconSystemName = tab.iconSystemName {
                Image(systemName: iconSystemName)
                    .cmuxFont(size: 11, weight: .medium)
                    .foregroundStyle(textColor)
            }
        }
        .frame(width: 14, height: 14)
        .background(CanvasTabHitRegionView(tabId: tab.id, kind: .close, registry: geometryRegistry))
    }

    private var tabBackground: some View {
        ZStack {
            if isSelected {
                Rectangle().fill(Color(nsColor: barBackground.cmuxCanvasActiveTabFill))
            } else if isHovered {
                Rectangle().fill(Color(nsColor: barBackground.cmuxCanvasHoverTabFill))
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
