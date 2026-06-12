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

/// The tab bar at the top of a canvas pane, mirroring the workspace split
/// pane tab bar's anatomy (30pt bar, full-height square tabs, right-edge
/// separators, selected/hover fills, icon slot that becomes a close glyph on
/// hover, 11pt centered titles). Render-only: all clicks and drags are
/// handled by `CanvasPaneView` via the reported hit regions.
struct CanvasPaneTitleBarView: View {
    let chrome: CanvasPaneChrome
    let onHitRegionsChanged: (CanvasTabHitRegions) -> Void

    /// Matches the split pane tab bar height.
    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            ForEach(chrome.tabs) { tab in
                CanvasPaneTabItem(
                    tab: tab,
                    isSelected: chrome.tabs.count == 1 || tab.id == chrome.selectedTabId,
                    paneIsFocused: chrome.isFocused
                )
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.height)
        .coordinateSpace(name: "canvasTabBar")
        .onPreferenceChange(CanvasTabFramesKey.self) { regions in
            onHitRegionsChanged(regions)
        }
    }
}

/// One tab, visually matching the workspace split pane tabs: full-height
/// rectangle, selected/hover background fill, a 1px trailing separator, and
/// an icon slot that swaps to a close glyph on hover.
private struct CanvasPaneTabItem: View {
    let tab: CanvasTabChrome
    let isSelected: Bool
    let paneIsFocused: Bool

    @State private var isHovered = false

    private var textOpacity: Double {
        isSelected && paneIsFocused ? 0.82 : 0.62
    }

    var body: some View {
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
        .onHover { isHovered = $0 }
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
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.82))
                    .frame(width: 16, height: 16)
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
