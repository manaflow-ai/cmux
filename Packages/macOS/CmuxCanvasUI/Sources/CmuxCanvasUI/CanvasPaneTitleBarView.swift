import CmuxFoundation
import SwiftUI

/// Hit rects for one rendered tab, in the tab bar's local coordinates.
/// Reported by the SwiftUI strip so `CanvasPaneView` can route AppKit mouse
/// events (select / close / drag) without SwiftUI gesture recognizers —
/// drags stay on the fast NSEvent path and never fight button recognizers.
struct CanvasTabHitRegions: Equatable {
    var tabFrames: [UUID: CGRect] = [:]
    var closeFrames: [UUID: CGRect] = [:]
}

private struct CanvasTabFramesKey: PreferenceKey {
    static let defaultValue = CanvasTabHitRegions()
    static func reduce(value: inout CanvasTabHitRegions, nextValue: () -> CanvasTabHitRegions) {
        let next = nextValue()
        value.tabFrames.merge(next.tabFrames) { _, new in new }
        value.closeFrames.merge(next.closeFrames) { _, new in new }
    }
}

private struct CanvasTabContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
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
    let onHitRegionsChanged: (CanvasTabHitRegions) -> Void
    let onContentWidthChanged: (CGFloat) -> Void

    /// Matches the split pane tab bar height.
    static let height: CGFloat = 30

    var body: some View {
        // Tabs are laid out left-aligned and shifted by -scrollOffset; the
        // named coordinate space is anchored to the (non-scrolling) bar, so
        // reported hit frames are already in post-scroll viewport coords and
        // a scrolled-out tab reports a frame outside the bar (no false hit).
        HStack(spacing: 0) {
            ForEach(chrome.tabs) { tab in
                CanvasPaneTabItem(
                    tab: tab,
                    isSelected: chrome.tabs.count == 1 || tab.id == chrome.selectedTabId,
                    isHovered: tab.id == hoveredTabId,
                    paneIsFocused: chrome.isFocused,
                    barBackground: barBackground
                )
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CanvasTabContentWidthKey.self, value: proxy.size.width)
            }
        )
        .fixedSize(horizontal: true, vertical: false)
        .offset(x: -scrollOffset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .clipped()
        .coordinateSpace(name: "canvasTabBar")
        .onPreferenceChange(CanvasTabFramesKey.self) { regions in
            MainActor.assumeIsolated {
                onHitRegionsChanged(regions)
            }
        }
        .onPreferenceChange(CanvasTabContentWidthKey.self) { width in
            MainActor.assumeIsolated {
                onContentWidthChanged(width)
            }
        }
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
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CanvasTabFramesKey.self,
                    value: CanvasTabHitRegions(
                        tabFrames: [tab.id: proxy.frame(in: .named("canvasTabBar"))]
                    )
                )
            }
        )
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
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CanvasTabFramesKey.self,
                    value: CanvasTabHitRegions(
                        closeFrames: [tab.id: proxy.frame(in: .named("canvasTabBar")).insetBy(dx: -4, dy: -7)]
                    )
                )
            }
        )
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
