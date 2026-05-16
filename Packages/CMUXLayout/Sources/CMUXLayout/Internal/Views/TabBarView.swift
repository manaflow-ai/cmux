import SwiftUI
import AppKit
import UniformTypeIdentifiers

public enum WorkspaceLayoutTabBarHitRegionRegistry {
    private static let lock = NSLock()
    private static let registeredViews = NSHashTable<NSView>.weakObjects()

    static func register(_ view: NSView) {
        lock.lock()
        registeredViews.add(view)
        lock.unlock()
    }

    static func unregister(_ view: NSView) {
        lock.lock()
        registeredViews.remove(view)
        lock.unlock()
    }

    private static func snapshot() -> [NSView] {
        lock.lock()
        let views = registeredViews.allObjects
        lock.unlock()
        return views
    }

    private static func isVisibleInHierarchy(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            guard !candidate.isHidden, candidate.alphaValue > 0 else { return false }
            current = candidate.superview
        }
        return true
    }

    public static func containsWindowPoint(_ windowPoint: CGPoint, in window: NSWindow) -> Bool {
        let epsilon = max(0.5, 1.0 / max(1.0, window.backingScaleFactor))
        for view in snapshot() {
            guard view.window === window, isVisibleInHierarchy(view) else { continue }
            let frameInWindow = view.convert(view.bounds, to: nil).insetBy(dx: -epsilon, dy: -epsilon)
            if frameInWindow.contains(windowPoint) {
                return true
            }
        }
        return false
    }
}

private struct SelectedTabFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() {
            value = next
        }
    }
}

private struct TabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SplitButtonLaneWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SplitButtonLaneWidthReader: View {
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: SplitButtonLaneWidthPreferenceKey.self,
                value: geometry.size.width
            )
        }
    }
}

@MainActor
private final class TabBarScrollViewBridge: ObservableObject {
    private struct ScrollMetrics {
        let offset: CGFloat
        let documentWidth: CGFloat
        let viewportWidth: CGFloat
    }

    weak var scrollView: NSScrollView?

    func attach(_ scrollView: NSScrollView?) {
        self.scrollView = scrollView
        enforceLeadingEdgeIfContentFits(reason: "attach")
    }

    private func currentMetrics() -> ScrollMetrics? {
        guard let scrollView else { return nil }

        let clipView = scrollView.contentView
        let documentWidth = max(
            scrollView.documentView?.frame.width ?? 0,
            scrollView.documentView?.bounds.width ?? 0
        )
        let viewportWidth = clipView.bounds.width
        return ScrollMetrics(
            offset: clipView.bounds.origin.x,
            documentWidth: documentWidth,
            viewportWidth: viewportWidth
        )
    }

    func shouldPreferLeadingTarget(
        selectedTabId: UUID?,
        fallbackContentWidth: CGFloat,
        fallbackContainerWidth: CGFloat
    ) -> Bool {
        guard selectedTabId != nil else { return true }

        if let metrics = currentMetrics(), metrics.viewportWidth > 0 {
            return TabBarStyling.shouldKeepLeadingAligned(
                contentWidth: metrics.documentWidth,
                containerWidth: metrics.viewportWidth
            )
        }

        return TabBarStyling.shouldKeepLeadingAligned(
            contentWidth: fallbackContentWidth,
            containerWidth: fallbackContainerWidth
        )
    }

    func enforceLeadingEdgeIfContentFits(reason: String) {
        guard let metrics = currentMetrics(), metrics.viewportWidth > 0 else { return }
        guard TabBarStyling.shouldKeepLeadingAligned(
            contentWidth: metrics.documentWidth,
            containerWidth: metrics.viewportWidth
        ) else {
            return
        }

        resetToLeadingEdgeIfNeeded(reason: reason)
    }

    func resetToLeadingEdgeIfNeeded(reason: String) {
        guard let metrics = currentMetrics() else { return }

        let currentOffset = metrics.offset
        guard abs(currentOffset) > 0.5 else { return }

        guard let scrollView else { return }
        #if DEBUG
        dlog(
            "tab.bar.resetLeading reason=\(reason) " +
            "offset=\(Int(currentOffset.rounded())) " +
            "doc=\(Int(metrics.documentWidth.rounded())) " +
            "viewport=\(Int(metrics.viewportWidth.rounded()))"
        )
#endif
        let clipView = scrollView.contentView
        clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)

        // SwiftUI's ScrollView can briefly restore the stale offset during the same
        // layout cycle. Re-apply the correction on the next turn to keep split-pane
        // tab bars pinned to the leading edge once they stop overflowing.
        DispatchQueue.main.async { [weak scrollView] in
            guard let scrollView else { return }
            let clipView = scrollView.contentView
            let asyncOffset = clipView.bounds.origin.x
            guard abs(asyncOffset) > 0.5 else { return }
#if DEBUG
            let documentWidth = max(
                scrollView.documentView?.frame.width ?? 0,
                scrollView.documentView?.bounds.width ?? 0
            )
            dlog(
                "tab.bar.resetLeading.async reason=\(reason) " +
                "offset=\(Int(asyncOffset.rounded())) " +
                "doc=\(Int(documentWidth.rounded())) " +
                "viewport=\(Int(clipView.bounds.width.rounded()))"
            )
#endif
            clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.origin.y))
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}

enum TabBarStyling {
    static let maximumSplitButtonLaneWidthFraction: CGFloat = 0.25
    static let splitButtonScrollFadeWidth: CGFloat = 12
    static let splitActionButtonReservedWidth: CGFloat = 22
    static let splitButtonsSpacing: CGFloat = 4
    static let splitButtonsLeadingPadding: CGFloat = 6
    static let splitButtonsTrailingPadding: CGFloat = 8

    static var splitButtonsBackdropWidth: CGFloat {
        splitButtonsBackdropWidth(buttonCount: WorkspaceLayoutConfiguration.SplitActionButton.defaults.count)
    }

    static func splitButtonsBackdropWidth(buttonCount: Int) -> CGFloat {
        guard buttonCount > 0 else { return 0 }
        return splitButtonsLeadingPadding
            + splitButtonsTrailingPadding
            + (CGFloat(buttonCount) * splitActionButtonReservedWidth)
            + (CGFloat(max(0, buttonCount - 1)) * splitButtonsSpacing)
    }

    static func splitButtonBackdropSolidSurfaceWidth(
        effectSolidWidth: CGFloat,
        visibleLaneWidth: CGFloat,
        solidSurfaceWidthAdjustment: CGFloat
    ) -> CGFloat {
        let adjustedLaneWidth = max(0, visibleLaneWidth + solidSurfaceWidthAdjustment)
        return max(max(0, effectSolidWidth), adjustedLaneWidth)
    }

    static func splitButtonContentOcclusionWidth(
        visibleLaneWidth: CGFloat,
        contentOcclusionFraction: CGFloat
    ) -> CGFloat {
        max(0, visibleLaneWidth) * min(max(0, contentOcclusionFraction), 1)
    }

    static func splitButtonScrollAffordances(
        scrollOffset: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> (left: Bool, right: Bool) {
        let overflowThreshold: CGFloat = 1
        let maxOffset = max(0, contentWidth - viewportWidth)
        return (
            left: scrollOffset > overflowThreshold,
            right: scrollOffset < maxOffset - overflowThreshold
        )
    }

    static func imageDataShouldRenderAsTemplate(_ data: Data) -> Bool {
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        let lowercased = text.lowercased()
        return lowercased.contains("<svg") && lowercased.contains("currentcolor")
    }

    static func splitActionButtonImage(from data: Data) -> NSImage? {
        SplitActionButtonImageCache.shared.image(for: data)
    }

    enum ScrollTarget: Equatable {
        case leading
        case selectedTab(UUID)
    }

    static func separatorSegments(
        totalWidth: CGFloat,
        gap: ClosedRange<CGFloat>?
    ) -> (left: CGFloat, right: CGFloat) {
        let clampedTotal = max(0, totalWidth)
        guard let gap else {
            return (left: clampedTotal, right: 0)
        }

        let start = min(max(gap.lowerBound, 0), clampedTotal)
        let end = min(max(gap.upperBound, 0), clampedTotal)
        let normalizedStart = min(start, end)
        let normalizedEnd = max(start, end)
        let left = max(0, normalizedStart)
        let right = max(0, clampedTotal - normalizedEnd)
        return (left: left, right: right)
    }

    static func trailingTabContentInset(
        showSplitButtons: Bool,
        isMinimalMode: Bool,
        buttonCount: Int = WorkspaceLayoutConfiguration.SplitActionButton.defaults.count
    ) -> CGFloat {
        guard showSplitButtons, buttonCount > 0 else { return 0 }

        // In minimal mode the split buttons fade in on hover as an overlay. Reserving that
        // width in the scroll content leaves a dead NSClipView strip when the buttons are
        // hidden, so clicks there never reach the tab-bar chrome.
        return isMinimalMode ? 0 : splitButtonsBackdropWidth(buttonCount: buttonCount)
    }

    static func preferredScrollTarget(
        selectedTabId: UUID?,
        contentWidth: CGFloat,
        containerWidth: CGFloat
    ) -> ScrollTarget {
        guard let selectedTabId else { return .leading }

        // When the tab strip fits without horizontal scrolling, centering the selected tab
        // can strand empty NSClipView space at the leading edge in split panes. Keep the
        // content snapped to the leading edge until it actually overflows.
        guard !shouldKeepLeadingAligned(contentWidth: contentWidth, containerWidth: containerWidth) else {
            return .leading
        }

        return .selectedTab(selectedTabId)
    }

    static func shouldKeepLeadingAligned(
        contentWidth: CGFloat,
        containerWidth: CGFloat
    ) -> Bool {
        let overflowThreshold: CGFloat = 1
        return contentWidth <= containerWidth + overflowThreshold
    }

    static func shouldForceResetToLeading(
        scrollOffset: CGFloat,
        contentWidth: CGFloat,
        containerWidth: CGFloat
    ) -> Bool {
        guard shouldKeepLeadingAligned(contentWidth: contentWidth, containerWidth: containerWidth) else {
            return false
        }

        let overflowThreshold: CGFloat = 1
        return abs(scrollOffset) > overflowThreshold
    }
}

struct TabBarLayout: Equatable {
    let barHeight: CGFloat
    let availableWidth: CGFloat
    let splitButtonCount: Int
    let splitButtonLaneVisible: Bool
    let reservesSplitButtonLane: Bool
    let measuredSplitButtonLaneWidth: CGFloat

    init(
        tabBarHeight: CGFloat,
        availableWidth: CGFloat = 0,
        splitButtonCount: Int,
        splitButtonLaneVisible: Bool,
        reservesSplitButtonLane: Bool,
        measuredSplitButtonLaneWidth: CGFloat = 0
    ) {
        self.barHeight = max(1, tabBarHeight)
        self.availableWidth = max(0, availableWidth)
        self.splitButtonCount = max(0, splitButtonCount)
        self.splitButtonLaneVisible = splitButtonLaneVisible
        self.reservesSplitButtonLane = reservesSplitButtonLane
        self.measuredSplitButtonLaneWidth = self.splitButtonCount > 0
            ? max(0, measuredSplitButtonLaneWidth)
            : 0
    }

    var minimumSplitButtonLaneWidth: CGFloat {
        TabBarStyling.splitButtonsBackdropWidth(buttonCount: splitButtonCount)
    }

    var fullSplitButtonLaneWidth: CGFloat {
        max(minimumSplitButtonLaneWidth, measuredSplitButtonLaneWidth)
    }

    var maximumSplitButtonLaneWidth: CGFloat {
        guard availableWidth > 0 else { return fullSplitButtonLaneWidth }
        return availableWidth * TabBarStyling.maximumSplitButtonLaneWidthFraction
    }

    var visibleSplitButtonLaneWidth: CGFloat {
        min(fullSplitButtonLaneWidth, maximumSplitButtonLaneWidth)
    }

    var splitButtonLaneOverflowsViewport: Bool {
        fullSplitButtonLaneWidth > visibleSplitButtonLaneWidth + 1
    }

    var trailingTabContentInset: CGFloat {
        reservesSplitButtonLane ? visibleSplitButtonLaneWidth : 0
    }

    var splitActionButtonHeight: CGFloat {
        barHeight
    }

    func selectedSeparatorGap(
        selectedTabFrame: CGRect?,
        totalWidth: CGFloat
    ) -> ClosedRange<CGFloat>? {
        guard let selectedTabFrame, totalWidth > 0 else { return nil }

        let minX = min(max(selectedTabFrame.minX, 0), totalWidth)
        let maxX = min(max(selectedTabFrame.maxX, 0), totalWidth)
        guard maxX > minX else { return nil }
        return minX...maxX
    }

    func selectedIndicatorFrame(
        selectedTabFrame: CGRect?,
        totalWidth: CGFloat
    ) -> CGRect? {
        guard let gap = selectedSeparatorGap(
            selectedTabFrame: selectedTabFrame,
            totalWidth: totalWidth
        ) else { return nil }

        let minX = gap.lowerBound
        let maxX = gap.upperBound
        let width = max(0, maxX - minX - TabBarMetrics.activeIndicatorTrailingInset)
        guard width > 0 else { return nil }

        return CGRect(
            x: minX,
            y: 0,
            width: width,
            height: TabBarMetrics.activeIndicatorHeight
        )
    }
}

struct TabBarActionLaneGeometry: Equatable {
    let buttonViewportWidth: CGFloat
    let contentFadeWidth: CGFloat
    let contentOcclusionWidth: CGFloat
    let backgroundFadeWidth: CGFloat
    let backgroundSolidWidth: CGFloat
    let separatorFadeWidth: CGFloat
    let backgroundFadeRampStartFraction: CGFloat

    init(
        layout: TabBarLayout,
        effect: WorkspaceLayoutConfiguration.Appearance.SplitButtonBackdropEffect,
        masksTabContent: Bool
    ) {
        self.buttonViewportWidth = layout.visibleSplitButtonLaneWidth
        self.contentFadeWidth = masksTabContent ? effect.contentFadeWidth : 0
        if masksTabContent {
            let fractionalOcclusionWidth = TabBarStyling.splitButtonContentOcclusionWidth(
                visibleLaneWidth: layout.visibleSplitButtonLaneWidth,
                contentOcclusionFraction: effect.contentOcclusionFraction
            )
            self.contentOcclusionWidth = layout.splitButtonLaneOverflowsViewport
                ? layout.visibleSplitButtonLaneWidth
                : fractionalOcclusionWidth
        } else {
            self.contentOcclusionWidth = 0
        }
        self.backgroundFadeWidth = max(0, effect.fadeWidth)
        let solidSurfaceWidthAdjustment = layout.splitButtonLaneOverflowsViewport
            ? max(0, effect.solidSurfaceWidthAdjustment)
            : effect.solidSurfaceWidthAdjustment
        self.backgroundSolidWidth = TabBarStyling.splitButtonBackdropSolidSurfaceWidth(
            effectSolidWidth: effect.solidWidth,
            visibleLaneWidth: layout.visibleSplitButtonLaneWidth,
            solidSurfaceWidthAdjustment: solidSurfaceWidthAdjustment
        )
        let rampStart = min(max(0, effect.fadeRampStartFraction), 0.95)
        self.backgroundFadeRampStartFraction = rampStart
        let defaultSeparatorFadeWidth = self.backgroundFadeWidth
        self.separatorFadeWidth = min(
            defaultSeparatorFadeWidth,
            effect.separatorFadeWidth ?? defaultSeparatorFadeWidth
        )
    }

    var separatorTotalWidth: CGFloat {
        separatorFadeWidth + backgroundSolidWidth
    }

    func backgroundFadeFrame(totalWidth: CGFloat, height: CGFloat) -> CGRect {
        let width = max(0, backgroundFadeWidth)
        return CGRect(
            x: totalWidth - backgroundSolidWidth - width,
            y: 0,
            width: width,
            height: height
        )
    }

    func backgroundSolidFrame(totalWidth: CGFloat, height: CGFloat) -> CGRect {
        let width = max(0, backgroundSolidWidth)
        return CGRect(
            x: totalWidth - width,
            y: 0,
            width: width,
            height: height
        )
    }

    func separatorFadeFrame(totalWidth: CGFloat, height: CGFloat) -> CGRect {
        let width = max(0, separatorFadeWidth)
        return CGRect(
            x: totalWidth - backgroundSolidWidth - width,
            y: height - 1,
            width: width,
            height: 1
        )
    }

    func separatorSolidFrame(totalWidth: CGFloat, height: CGFloat) -> CGRect {
        let solid = backgroundSolidFrame(totalWidth: totalWidth, height: height)
        return CGRect(x: solid.minX, y: height - 1, width: solid.width, height: 1)
    }

    func separatorCoverageFrame(totalWidth: CGFloat, height: CGFloat) -> CGRect {
        let width = separatorTotalWidth
        return CGRect(x: totalWidth - width, y: height - 1, width: width, height: 1)
    }

    func fallbackSeparatorMaskFrame(
        totalWidth: CGFloat,
        height: CGFloat,
        selectedSeparatorGap: ClosedRange<CGFloat>?
    ) -> CGRect? {
        guard let selectedSeparatorGap else { return nil }
        let coverage = separatorCoverageFrame(totalWidth: totalWidth, height: height)
        let start = max(coverage.minX, selectedSeparatorGap.lowerBound)
        let end = min(coverage.maxX, selectedSeparatorGap.upperBound)
        guard end > start else { return nil }
        return CGRect(x: start, y: height - 1, width: end - start, height: 1)
    }
}

struct TabBarChromeSnapshot {
    let layout: TabBarLayout
    let actionLaneGeometry: TabBarActionLaneGeometry
    let barColor: NSColor
    let actionLaneWidth: CGFloat
    let paintsActionLaneSurface: Bool
    let masksTabContentUnderActionLane: Bool
    let contentFadeWidth: CGFloat
    let contentOcclusionWidth: CGFloat
    let actionLaneSeparatorFadeWidth: CGFloat
    let backdropFadeWidth: CGFloat
    let backdropSolidWidth: CGFloat
    let backdropFadeRampStartFraction: CGFloat
    let backdropLeadingColor: NSColor
    let backdropTrailingColor: NSColor

    var drawsActionLaneSeparator: Bool {
        paintsActionLaneSurface || masksTabContentUnderActionLane
    }

    var backdropVisibleFadeWidth: CGFloat {
        backdropFadeWidth * (1 - backdropFadeRampStartFraction)
    }

    var actionLaneSeparatorSolidWidth: CGFloat {
        actionLaneGeometry.backgroundSolidWidth
    }

    init(
        appearance: WorkspaceLayoutConfiguration.Appearance,
        layout: TabBarLayout,
        isFocused: Bool,
        shouldShowSplitButtons: Bool,
        fadeColorStyle: Int
    ) {
        self.layout = layout

        let baseBarColor = TabBarColors.nsColorBarBackground(for: appearance)
        self.barColor = appearance.usesSharedBackdrop || isFocused
            ? baseBarColor
            : baseBarColor.withAlphaComponent(baseBarColor.alphaComponent * 0.95)

        let effect = Self.splitButtonBackdropEffect(
            for: appearance,
            fadeColorStyle: fadeColorStyle
        )
        let targetColor = Self.buttonBackdropColor(
            for: appearance,
            focused: isFocused,
            style: effect.style
        )
        let colors = Self.splitButtonBackdropColors(
            from: barColor,
            to: targetColor,
            leadingOpacity: effect.leadingOpacity,
            trailingOpacity: effect.trailingOpacity,
            usesSharedBackdrop: appearance.usesSharedBackdrop
        )

        let canUseActionLaneChrome = shouldShowSplitButtons && effect.style != .hidden
        self.paintsActionLaneSurface = canUseActionLaneChrome
            && TabBarColors.shouldPaintSplitButtonBackdrop(for: appearance)
        self.masksTabContentUnderActionLane = canUseActionLaneChrome && effect.masksTabContent
        let geometry = TabBarActionLaneGeometry(
            layout: layout,
            effect: effect,
            masksTabContent: masksTabContentUnderActionLane
        )
        self.actionLaneGeometry = geometry
        self.actionLaneWidth = geometry.buttonViewportWidth
        self.contentFadeWidth = geometry.contentFadeWidth
        self.contentOcclusionWidth = geometry.contentOcclusionWidth
        self.backdropFadeWidth = geometry.backgroundFadeWidth
        self.backdropSolidWidth = geometry.backgroundSolidWidth
        self.backdropFadeRampStartFraction = min(max(0, effect.fadeRampStartFraction), 0.95)
        self.actionLaneSeparatorFadeWidth = geometry.separatorFadeWidth
        self.backdropLeadingColor = colors.leading
        self.backdropTrailingColor = colors.trailing
    }

    private static func splitButtonBackdropEffect(
        for appearance: WorkspaceLayoutConfiguration.Appearance,
        fadeColorStyle: Int
    ) -> WorkspaceLayoutConfiguration.Appearance.SplitButtonBackdropEffect {
        if let effect = appearance.splitButtonBackdropEffect {
            return effect
        }
        if let style = appearance.splitButtonBackdropStyle {
            return .init(style: style)
        }
        if let debugStyle = WorkspaceLayoutConfiguration.Appearance.SplitButtonBackdropStyle(rawValue: fadeColorStyle) {
            return .init(
                style: debugStyle,
                fadeWidth: 136,
                solidWidth: 2,
                fadeRampStartFraction: 0.80,
                leadingOpacity: 0,
                trailingOpacity: 0.80,
                masksTabContent: false
            )
        }
        return .default
    }

    private static func buttonBackdropColor(
        for appearance: WorkspaceLayoutConfiguration.Appearance,
        focused: Bool,
        style: WorkspaceLayoutConfiguration.Appearance.SplitButtonBackdropStyle
    ) -> NSColor {
        if appearance.usesSharedBackdrop {
            return TabBarColors.nsColorSplitButtonBackdropOccludingSurface(for: appearance)
        }

        switch style {
        case .opaquePaneBackground:
            return TabBarColors.nsColorPaneBackground(for: appearance).withAlphaComponent(1.0)
        case .opaqueBarBackground:
            return TabBarColors.nsColorBarBackground(for: appearance).withAlphaComponent(1.0)
        case .windowBackground:
            return NSColor.windowBackgroundColor.withAlphaComponent(1.0)
        case .controlBackground:
            return NSColor.controlBackgroundColor.withAlphaComponent(1.0)
        case .precompositedBarBackground:
            let chrome = TabBarColors.nsColorBarBackground(for: appearance)
            let winBg = NSColor.windowBackgroundColor
            guard let fg = chrome.usingColorSpace(.sRGB),
                  let bk = winBg.usingColorSpace(.sRGB) else {
                return chrome.withAlphaComponent(1.0)
            }
            let a: CGFloat = focused ? fg.alphaComponent : fg.alphaComponent * 0.95
            let oneMinusA = 1.0 - a
            let r = fg.redComponent * a + bk.redComponent * oneMinusA
            let g = fg.greenComponent * a + bk.greenComponent * oneMinusA
            let b = fg.blueComponent * a + bk.blueComponent * oneMinusA
            return NSColor(red: r, green: g, blue: b, alpha: 1.0)
        case .translucentChrome:
            let backdrop = TabBarColors.nsColorSplitButtonBackdropSurface(for: appearance)
            let alpha = focused ? backdrop.alphaComponent : backdrop.alphaComponent * 0.95
            return backdrop.withAlphaComponent(alpha)
        case .hidden:
            return .clear
        case .precompositedPaneBackground:
            return TabBarColors.nsColorSplitButtonBackdrop(for: appearance, focused: focused)
        }
    }

    private static func blendedSurfaceColor(
        from base: NSColor,
        to target: NSColor,
        amount: CGFloat
    ) -> NSColor {
        let clampedAmount = min(max(amount, 0), 1)
        let source = base.usingColorSpace(.sRGB) ?? base
        let destination = target.usingColorSpace(.sRGB) ?? target
        let inverse = 1 - clampedAmount
        return NSColor(
            red: source.redComponent * inverse + destination.redComponent * clampedAmount,
            green: source.greenComponent * inverse + destination.greenComponent * clampedAmount,
            blue: source.blueComponent * inverse + destination.blueComponent * clampedAmount,
            alpha: source.alphaComponent * inverse + destination.alphaComponent * clampedAmount
        )
    }

    private static func splitButtonBackdropColors(
        from base: NSColor,
        to target: NSColor,
        leadingOpacity: CGFloat,
        trailingOpacity: CGFloat,
        usesSharedBackdrop: Bool
    ) -> (leading: NSColor, trailing: NSColor) {
        if usesSharedBackdrop {
            return (
                alphaOnlySurfaceColor(target, opacity: leadingOpacity),
                alphaOnlySurfaceColor(target, opacity: trailingOpacity)
            )
        }

        return (
            blendedSurfaceColor(from: base, to: target, amount: leadingOpacity),
            blendedSurfaceColor(from: base, to: target, amount: trailingOpacity)
        )
    }

    private static func alphaOnlySurfaceColor(
        _ color: NSColor,
        opacity: CGFloat
    ) -> NSColor {
        let clampedOpacity = min(max(opacity, 0), 1)
        guard let source = color.usingColorSpace(.sRGB) else {
            return color.withAlphaComponent(color.alphaComponent * clampedOpacity)
        }
        return NSColor(
            red: source.redComponent,
            green: source.greenComponent,
            blue: source.blueComponent,
            alpha: source.alphaComponent * clampedOpacity
        )
    }
}

struct TabContextMenuState {
    let isPinned: Bool
    let isUnread: Bool
    let isBrowser: Bool
    let isTerminal: Bool
    let hasCustomTitle: Bool
    let canCloseToLeft: Bool
    let canCloseToRight: Bool
    let canCloseOthers: Bool
    let canMoveToNewWorkspace: Bool
    let canMoveToLeftPane: Bool
    let canMoveToRightPane: Bool
    let isZoomed: Bool
    let hasSplits: Bool
    let moveDestinations: [SurfaceMoveDestination]
    let shortcuts: [SurfaceContextAction: KeyboardShortcut]

    var canMarkAsUnread: Bool {
        !isUnread
    }

    var canMarkAsRead: Bool {
        isUnread
    }
}

/// SurfaceTab bar view with scrollable tabs, drag/drop support, and split buttons
struct TabBarView: View {
    @Environment(WorkspaceLayoutController.self) private var controller
    @Environment(SplitViewController.self) private var splitViewController
    
    @Bindable var pane: PaneState
    let isFocused: Bool
    var showSplitButtons: Bool = true

    @AppStorage("workspacePresentationMode") private var presentationMode = "standard"
    @AppStorage("debugFadeColorStyle") private var fadeColorStyle = -1
    @State private var isHoveringTabBar = false
    @State private var dropTargetIndex: Int?
    @State private var dropLifecycle: TabDropLifecycle = .idle
    @State private var scrollOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var selectedTabFrameInBar: CGRect?
    @State private var tabFramesInBar: [UUID: CGRect] = [:]
    @State private var measuredSplitButtonLaneWidth: CGFloat = 0
    @State private var splitButtonScrollOffset: CGFloat = 0
    @State private var splitButtonContentWidth: CGFloat = 0
    @State private var splitButtonViewportWidth: CGFloat = 0
    @StateObject private var controlKeyMonitor = TabControlShortcutKeyMonitor()
    @StateObject private var scrollViewBridge = TabBarScrollViewBridge()

    private var canScrollLeft: Bool {
        scrollOffset > 1
    }

    private var canScrollRight: Bool {
        // contentWidth includes the 30pt drop zone after tabs.
        let tabsWidth = contentWidth - 30
        guard tabsWidth > containerWidth + 4 else { return false }
        return scrollOffset < tabsWidth - containerWidth
    }

    /// Whether this tab bar should show full saturation (focused or drag source)
    private var shouldShowFullSaturation: Bool {
        isFocused || splitViewController.dragSourcePaneId == pane.id
    }

    private var tabBarSaturation: Double {
        shouldShowFullSaturation ? 1.0 : 0.0
    }

    private var appearance: WorkspaceLayoutConfiguration.Appearance {
        controller.configuration.appearance
    }

    private var tabBarHeight: CGFloat {
        tabBarLayout.barHeight
    }

    private var tabBarLayout: TabBarLayout {
        TabBarLayout(
            tabBarHeight: appearance.tabBarHeight,
            availableWidth: containerWidth,
            splitButtonCount: visibleSplitButtons.count,
            splitButtonLaneVisible: shouldShowSplitButtons,
            reservesSplitButtonLane: showSplitButtons && !isMinimalMode,
            measuredSplitButtonLaneWidth: measuredSplitButtonLaneWidth
        )
    }

    private var chromeSnapshot: TabBarChromeSnapshot {
        TabBarChromeSnapshot(
            appearance: appearance,
            layout: tabBarLayout,
            isFocused: isFocused,
            shouldShowSplitButtons: shouldShowSplitButtons,
            fadeColorStyle: fadeColorStyle
        )
    }

    private var visibleSplitButtons: [WorkspaceLayoutConfiguration.SplitActionButton] {
        guard showSplitButtons else { return [] }
        return appearance.splitButtons
    }

    private var shouldRenderSplitButtons: Bool {
        !visibleSplitButtons.isEmpty
    }

    private var shouldShowSplitButtons: Bool {
        shouldRenderSplitButtons && (!isMinimalMode || isHoveringTabBar)
    }

    private var splitButtonsBackdropWidth: CGFloat {
        chromeSnapshot.actionLaneWidth
    }

    private var showsControlShortcutHints: Bool {
        isFocused && splitViewController.tabShortcutHintsEnabled && controlKeyMonitor.isShortcutHintVisible
    }

    private var isMinimalMode: Bool {
        presentationMode == "minimal"
    }

    private var trailingTabContentInset: CGFloat {
        tabBarLayout.trailingTabContentInset
    }

    private var leadingScrollAnchorId: String {
        "tab-bar-leading-\(pane.id.id.uuidString)"
    }

    private var splitButtonScrollCoordinateSpaceName: String {
        "split-button-scroll-\(pane.id.id.uuidString)"
    }

    private var splitButtonScrollAffordances: (left: Bool, right: Bool) {
        TabBarStyling.splitButtonScrollAffordances(
            scrollOffset: splitButtonScrollOffset,
            contentWidth: splitButtonContentWidth,
            viewportWidth: splitButtonViewportWidth
        )
    }

    private func focusPaneFromTabBarChrome() -> Bool {
        guard !isFocused else { return false }
        withTransaction(Transaction(animation: nil)) {
            controller.focusPane(pane.id)
        }
        return true
    }

    private func scrollToPreferredTarget(_ proxy: ScrollViewProxy, selectedTabId: UUID?) {
        let target: TabBarStyling.ScrollTarget
        if scrollViewBridge.shouldPreferLeadingTarget(
            selectedTabId: selectedTabId,
            fallbackContentWidth: contentWidth,
            fallbackContainerWidth: containerWidth
        ) {
            target = .leading
        } else if let selectedTabId {
            target = .selectedTab(selectedTabId)
        } else {
            target = .leading
        }

        withTransaction(Transaction(animation: nil)) {
            switch target {
            case .leading:
                proxy.scrollTo(leadingScrollAnchorId, anchor: .leading)
            case .selectedTab(let tabId):
                proxy.scrollTo(tabId, anchor: .center)
            }
        }

        if target == .leading,
           TabBarStyling.shouldForceResetToLeading(
                scrollOffset: scrollOffset,
                contentWidth: contentWidth,
                containerWidth: containerWidth
           ) {
            scrollViewBridge.resetToLeadingEdgeIfNeeded(reason: "scrollToPreferredTarget")
        } else if target == .leading {
            scrollViewBridge.enforceLeadingEdgeIfContentFits(reason: "scrollToPreferredTarget")
        }
    }


    var body: some View {
        HStack(spacing: 0) {
            if appearance.tabBarLeadingInset > 0 && controller.internalController.rootNode.allPaneIds.first == pane.id {
                TabBarDragZoneView(
                    isMinimalMode: isMinimalMode,
                    isFocusedPane: isFocused,
                    onSingleClick: focusPaneFromTabBarChrome
                ) { return false }
                    .frame(width: appearance.tabBarLeadingInset)
            }
            // Scrollable tabs with fade overlays
            GeometryReader { containerGeo in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: TabBarMetrics.tabSpacing) {
                            Color.clear
                                .frame(width: 0, height: tabBarHeight)
                                .id(leadingScrollAnchorId)

                            ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                                tabItem(for: tab, at: index)
                                    .id(tab.id)
                            }

                            // Unified drop zone after the last tab.
                            dropZoneAfterTabs
                        }
                        .padding(.horizontal, TabBarMetrics.barPadding)
                        .padding(.trailing, trailingTabContentInset)
                        .frame(height: tabBarHeight, alignment: .top)
                        .animation(nil, value: pane.tabs.map(\.id))
                        .background(
                            GeometryReader { contentGeo in
                                Color.clear
                                    .onChange(of: contentGeo.frame(in: .named("tabScroll"))) { _, newFrame in
                                        scrollOffset = -newFrame.minX
                                        contentWidth = newFrame.width
                                    }
                                    .onAppear {
                                        let frame = contentGeo.frame(in: .named("tabScroll"))
                                        scrollOffset = -frame.minX
                                        contentWidth = frame.width
                                    }
                            }
                        )
                    }
                    .background(
                        TabBarScrollViewResolver { scrollView in
                            scrollViewBridge.attach(scrollView)
                        }
                        .frame(width: 0, height: 0)
                    )
                    // When the tab strip is shorter than the visible area, place a single
                    // drag zone over both the empty trailing space AND the 30pt inline
                    // dropZoneAfterTabs (extended leftward by 30pt). The inline zone's
                    // DragNSView is then visually covered, so all clicks in this region land
                    // on this overlay's single DragNSView. AppKit tracks `clickCount` per
                    // view, so without this an unlucky shift in the inline/overlay boundary
                    // between two clicks would split a double-click into two clickCount=1
                    // events and the new-tab action would never fire.
                    .overlay(alignment: .trailing) {
                        let trailing = max(0, containerGeo.size.width - contentWidth)
                        if trailing >= 1 {
                            TabBarDragZoneView(
                                isMinimalMode: isMinimalMode,
                                isFocusedPane: isFocused,
                                onSingleClick: focusPaneFromTabBarChrome
                            ) {
                                performNewTerminalSplitButtonAction()
                            }
                            .frame(width: trailing + 30, height: tabBarHeight)
                            .onDrop(of: [.tabTransfer, .fileURL], delegate: TabDropDelegate(
                                targetIndex: pane.tabs.count,
                                pane: pane,
                                layoutController: controller,
                                controller: splitViewController,
                                dropTargetIndex: $dropTargetIndex,
                                dropLifecycle: $dropLifecycle
                            ))
                        }
                    }
                    .coordinateSpace(name: "tabScroll")
                    .onAppear {
                        containerWidth = containerGeo.size.width
                        scrollToPreferredTarget(proxy, selectedTabId: pane.selectedTabId)
                    }
                    .onChange(of: containerGeo.size.width) { _, newWidth in
                        containerWidth = newWidth
                        scrollToPreferredTarget(proxy, selectedTabId: pane.selectedTabId)
                    }
                    .onChange(of: contentWidth) { _, _ in
                        scrollToPreferredTarget(proxy, selectedTabId: pane.selectedTabId)
                    }
                    .onChange(of: pane.selectedTabId) { _, newTabId in
                        scrollToPreferredTarget(proxy, selectedTabId: newTabId)
                    }
                }
                .frame(height: tabBarHeight)
                .mask(combinedMask)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: tabBarHeight)
        .coordinateSpace(name: "tabBar")
        .background(tabBarSurface)
        .overlay(maskedSelectedTabIndicatorChrome)
        .overlay(alignment: .trailing) {
            splitButtonBackdropChrome
                .opacity(shouldShowSplitButtons ? 1 : 0)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.14), value: shouldShowSplitButtons)
        }
        .overlay(maskedTabBarBottomSeparatorChrome)
        .overlay {
            TabBarDragZoneView(
                hitRegion: .trailingEmptyChrome(
                    tabFrames: Array(tabFramesInBar.values),
                    reservedTrailingWidth: shouldRenderSplitButtons ? splitButtonsBackdropWidth : 0
                ),
                isMinimalMode: isMinimalMode,
                isFocusedPane: isFocused,
                onSingleClick: focusPaneFromTabBarChrome
            ) {
                performNewTerminalSplitButtonAction()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .trailing) {
            splitButtonChrome
                .frame(width: splitButtonsBackdropWidth, height: tabBarHeight, alignment: .trailing)
                .mask {
                    Rectangle()
                        .frame(width: splitButtonsBackdropWidth, height: tabBarHeight)
                }
                .clipped()
        }
        .background(TabBarDragAndHoverView(
            isMinimalMode: isMinimalMode,
            onDoubleClick: {
                performNewTerminalSplitButtonAction()
            },
            onHoverChanged: { isHoveringTabBar = $0 }
        ))
        .overlay(
            TabBarHoverTrackingView { isHoveringTabBar = $0 }
        )
        .overlay(
            TabBarManualReorderTrackingView(
                pane: pane,
                layoutController: controller,
                splitViewController: splitViewController,
                tabFrames: tabFramesInBar,
                dropTargetIndex: $dropTargetIndex,
                dropLifecycle: $dropLifecycle
            )
        )
        .background(
            TabBarHostWindowReader { window in
                controlKeyMonitor.setHostWindow(window)
            }
            .frame(width: 0, height: 0)
        )
        // Clear drop state when drag ends elsewhere (cancelled, dropped in another pane, etc.)
        .onChange(of: splitViewController.draggingTab) { _, newValue in
#if DEBUG
            dlog(
                "tab.dragState pane=\(pane.id.id.uuidString.prefix(5)) " +
                "draggingTab=\(newValue != nil ? 1 : 0) " +
                "activeDragTab=\(splitViewController.activeDragTab != nil ? 1 : 0)"
            )
#endif
            if newValue == nil {
                dropTargetIndex = nil
                dropLifecycle = .idle
            }
        }
        .onAppear {
            controlKeyMonitor.start()
        }
        .onPreferenceChange(SelectedTabFramePreferenceKey.self) { frame in
            selectedTabFrameInBar = frame
        }
        .onPreferenceChange(TabFramePreferenceKey.self) { frames in
            tabFramesInBar = frames
        }
        .onPreferenceChange(SplitButtonLaneWidthPreferenceKey.self) { width in
            measuredSplitButtonLaneWidth = width
        }
        .onDisappear {
            controlKeyMonitor.stop()
        }
    }

    // MARK: - SurfaceTab Item

    @ViewBuilder
    private func tabItem(for tab: SurfaceItem, at index: Int) -> some View {
        let contextMenuState = contextMenuState(for: tab, at: index)
        let showsZoomIndicator = splitViewController.zoomedPaneId == pane.id && pane.selectedTabId == tab.id
        let isImmediatelyBeforeSelected = pane.tabs.indices.contains(index + 1)
            && pane.tabs[index + 1].id == pane.selectedTabId
        SurfaceItemView(
            tab: tab,
            isSelected: pane.selectedTabId == tab.id,
            showsZoomIndicator: showsZoomIndicator,
            appearance: appearance,
            saturation: tabBarSaturation,
            trailingSeparatorBottomInset: isImmediatelyBeforeSelected
                ? TabBarMetrics.selectedTabLeftSeparatorBottomInset
                : 0,
            controlShortcutDigit: tabControlShortcutDigit(for: index, tabCount: pane.tabs.count),
            allowsShortcutHints: isFocused && splitViewController.tabShortcutHintsEnabled,
            showsControlShortcutHint: showsControlShortcutHints,
            shortcutModifierSymbol: controlKeyMonitor.shortcutModifierSymbol,
            contextMenuState: contextMenuState,
            onSelect: {
                // SurfaceTab selection must be instant. Animating this transaction causes the pane
                // content (often swapped via opacity) to crossfade, which is undesirable for
                // terminal/browser surfaces.
#if DEBUG
                dlog("tab.select pane=\(pane.id.id.uuidString.prefix(5)) tab=\(tab.id.uuidString.prefix(5)) title=\"\(tab.title)\"")
#endif
                withTransaction(Transaction(animation: nil)) {
                    controller.selectTab(SurfaceID(id: tab.id))
                }
            },
            onClose: {
                guard !tab.isPinned else { return }
                // Close should be instant (no fade-out/removal animation).
#if DEBUG
                dlog("tab.close pane=\(pane.id.id.uuidString.prefix(5)) tab=\(tab.id.uuidString.prefix(5)) title=\"\(tab.title)\"")
#endif
                withTransaction(Transaction(animation: nil)) {
                    controller.onTabCloseRequest?(SurfaceID(id: tab.id), pane.id)
                    _ = controller.closeTab(SurfaceID(id: tab.id), inPane: pane.id)
                }
            },
            onZoomToggle: {
                _ = splitViewController.togglePaneZoom(pane.id)
            },
            onContextAction: { action in
                controller.requestSurfaceContextAction(action, for: SurfaceID(id: tab.id), inPane: pane.id)
            },
            onMoveDestination: { destinationId in
                controller.requestTabMove(toDestination: destinationId, for: SurfaceID(id: tab.id), inPane: pane.id)
            }
        )
        .background(
            GeometryReader { geometry in
                let frame = geometry.frame(in: .named("tabBar"))
                Color.clear
                    .preference(
                        key: SelectedTabFramePreferenceKey.self,
                        value: pane.selectedTabId == tab.id ? frame : nil
                    )
                    .preference(
                        key: TabFramePreferenceKey.self,
                        value: [tab.id: frame]
                    )
            }
        )
        .onDrag {
            createItemProvider(for: tab)
        } preview: {
            TabDragPreview(tab: tab, appearance: appearance)
        }
        .onDrop(of: [.tabTransfer, .fileURL], delegate: TabDropDelegate(
            targetIndex: index,
            pane: pane,
            layoutController: controller,
            controller: splitViewController,
            dropTargetIndex: $dropTargetIndex,
            dropLifecycle: $dropLifecycle
        ))
        .overlay(alignment: .leading) {
            if dropTargetIndex == index {
                dropIndicator
                    .accessibilityIdentifier("paneTabBar.dropIndicator")
                    .saturation(tabBarSaturation)
            }
        }
    }

    private func contextMenuState(for tab: SurfaceItem, at index: Int) -> TabContextMenuState {
        let leftTabs = pane.tabs.prefix(index)
        let canCloseToLeft = leftTabs.contains(where: { !$0.isPinned })
        let canCloseToRight: Bool
        if (index + 1) < pane.tabs.count {
            canCloseToRight = pane.tabs.suffix(from: index + 1).contains(where: { !$0.isPinned })
        } else {
            canCloseToRight = false
        }
        let canCloseOthers = pane.tabs.enumerated().contains { itemIndex, item in
            itemIndex != index && !item.isPinned
        }
        return TabContextMenuState(
            isPinned: tab.isPinned,
            isUnread: tab.showsNotificationBadge,
            isBrowser: tab.kind == "browser",
            isTerminal: tab.kind == "terminal",
            hasCustomTitle: tab.hasCustomTitle,
            canCloseToLeft: canCloseToLeft,
            canCloseToRight: canCloseToRight,
            canCloseOthers: canCloseOthers,
            canMoveToNewWorkspace: controller.allTabIds.count > 1,
            canMoveToLeftPane: controller.adjacentPane(to: pane.id, direction: .left) != nil,
            canMoveToRightPane: controller.adjacentPane(to: pane.id, direction: .right) != nil,
            isZoomed: splitViewController.zoomedPaneId == pane.id,
            hasSplits: splitViewController.rootNode.allPaneIds.count > 1,
            moveDestinations: controller.tabContextMoveDestinationsProvider?(SurfaceID(id: tab.id), pane.id) ?? [],
            shortcuts: controller.contextMenuShortcuts
        )
    }

    // MARK: - Item Provider

    private func createItemProvider(for tab: SurfaceItem) -> NSItemProvider {
        #if DEBUG
        NSLog("[CMUXLayout Drag] createItemProvider for tab: \(tab.title)")
        #endif
#if DEBUG
        dlog("tab.dragStart pane=\(pane.id.id.uuidString.prefix(5)) tab=\(tab.id.uuidString.prefix(5)) title=\"\(tab.title)\"")
#endif
        // Clear any stale drop indicator from previous incomplete drag
        dropTargetIndex = nil
        dropLifecycle = .idle

        // Set drag source for visual feedback (observable) and drop delegates (non-observable).
        splitViewController.dragGeneration += 1
        splitViewController.draggingTab = tab
        splitViewController.dragSourcePaneId = pane.id
        splitViewController.activeDragTab = tab
        splitViewController.activeDragSourcePaneId = pane.id

        // Install a one-shot mouse-up monitor to clear stale drag state if the drag is
        // cancelled (dropped outside any valid target). SwiftUI's onDrag doesn't provide
        // a drag-cancelled callback, so performDrop never fires and draggingTab stays set,
        // which disables hit testing on all content views.
        let controller = splitViewController
        let dragGen = controller.dragGeneration
        var monitorRef: Any?
        monitorRef = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            // One-shot: remove ourselves, then clean up stale drag state.
            if let m = monitorRef {
                NSEvent.removeMonitor(m)
                monitorRef = nil
            }
            // Use async to avoid mutating @Observable state during event dispatch.
            DispatchQueue.main.async {
                guard controller.dragGeneration == dragGen else { return }
                if controller.draggingTab != nil || controller.activeDragTab != nil {
#if DEBUG
                    dlog("tab.dragCancel (stale draggingTab cleared)")
#endif
                    controller.draggingTab = nil
                    controller.dragSourcePaneId = nil
                    controller.activeDragTab = nil
                    controller.activeDragSourcePaneId = nil
                }
            }
            return event
        }

        let transfer = TabTransferData(tab: tab, sourcePaneId: pane.id.id)
        if let data = try? JSONEncoder().encode(transfer) {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.tabTransfer.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
#if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                let types = NSPasteboard(name: .drag).types?.map(\.rawValue).joined(separator: ",") ?? "-"
                dlog("tab.dragPasteboard types=\(types)")
            }
#endif
            return provider
        }
        return NSItemProvider()
    }

    private func tabControlShortcutDigit(for index: Int, tabCount: Int) -> Int? {
        for digit in 1...9 {
            if tabIndexForControlShortcutDigit(digit, tabCount: tabCount) == index {
                return digit
            }
        }
        return nil
    }

    private func tabIndexForControlShortcutDigit(_ digit: Int, tabCount: Int) -> Int? {
        guard tabCount > 0, digit >= 1, digit <= 9 else { return nil }
        if digit == 9 {
            return tabCount - 1
        }
        let index = digit - 1
        return index < tabCount ? index : nil
    }

    // MARK: - Drop Zone at End

    @ViewBuilder
    private var dropZoneAfterTabs: some View {
        TabBarDragZoneView(
            isMinimalMode: isMinimalMode,
            isFocusedPane: isFocused,
            onSingleClick: focusPaneFromTabBarChrome
        ) {
            performNewTerminalSplitButtonAction()
        }
        .frame(width: 30, height: tabBarHeight)
        .onDrop(of: [.tabTransfer, .fileURL], delegate: TabDropDelegate(
            targetIndex: pane.tabs.count,
            pane: pane,
            layoutController: controller,
            controller: splitViewController,
            dropTargetIndex: $dropTargetIndex,
            dropLifecycle: $dropLifecycle
        ))
        .overlay(alignment: .leading) {
            if dropTargetIndex == pane.tabs.count {
                dropIndicator
                    .accessibilityIdentifier("paneTabBar.dropIndicator")
                    .saturation(tabBarSaturation)
            }
        }
    }

    // MARK: - Drop Indicator

    @ViewBuilder
    private var dropIndicator: some View {
        Capsule()
            .fill(TabBarColors.dropIndicator(for: appearance))
            .frame(width: TabBarMetrics.dropIndicatorWidth, height: TabBarMetrics.dropIndicatorHeight)
            .offset(x: -1)
    }

    // MARK: - Split Buttons

    @ViewBuilder
    private var splitButtonChrome: some View {
        if shouldRenderSplitButtons {
            splitButtons
                .saturation(tabBarSaturation)
                .opacity(shouldShowSplitButtons ? 1 : 0)
                .allowsHitTesting(shouldShowSplitButtons)
            .frame(height: tabBarHeight, alignment: .trailing)
            .animation(.easeInOut(duration: 0.14), value: shouldShowSplitButtons)
        }
    }

    @ViewBuilder
    private var splitButtonBackdropChrome: some View {
        let snapshot = chromeSnapshot
        if snapshot.drawsActionLaneSeparator {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    if snapshot.paintsActionLaneSurface {
                        splitButtonBackdropSurface(snapshot: snapshot, totalWidth: geometry.size.width)
                    }

                    splitButtonFallbackSeparator(snapshot: snapshot, totalWidth: geometry.size.width)
                }
                .frame(width: geometry.size.width, height: tabBarHeight, alignment: .topLeading)
            }
            .frame(height: tabBarHeight)
        }
    }

    @ViewBuilder
    private func splitButtonBackdropSurface(snapshot: TabBarChromeSnapshot, totalWidth: CGFloat) -> some View {
        let geometry = snapshot.actionLaneGeometry
        let fadeFrame = geometry.backgroundFadeFrame(totalWidth: totalWidth, height: tabBarHeight)
        let solidFrame = geometry.backgroundSolidFrame(totalWidth: totalWidth, height: tabBarHeight)
        ZStack(alignment: .topLeading) {
            if fadeFrame.width > 0 {
                splitButtonBackdropFadeSegment(snapshot: snapshot)
                    .frame(width: fadeFrame.width, height: fadeFrame.height)
                    .offset(x: fadeFrame.minX, y: fadeFrame.minY)
            }
            if solidFrame.width > 0 {
                TabBarLayerBackedColor(color: snapshot.backdropTrailingColor)
                    .frame(width: solidFrame.width, height: solidFrame.height)
                    .offset(x: solidFrame.minX, y: solidFrame.minY)
            }
        }
        .frame(width: totalWidth, height: tabBarHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func splitButtonBackdropFadeSegment(snapshot: TabBarChromeSnapshot) -> some View {
        let rampStart = snapshot.backdropFadeRampStartFraction
        LinearGradient(
            stops: [
                .init(color: Color(nsColor: snapshot.backdropLeadingColor), location: 0),
                .init(color: Color(nsColor: snapshot.backdropLeadingColor), location: rampStart),
                .init(color: Color(nsColor: snapshot.backdropTrailingColor), location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    @ViewBuilder
    private func splitButtonFallbackSeparator(snapshot: TabBarChromeSnapshot, totalWidth: CGFloat) -> some View {
        let geometry = snapshot.actionLaneGeometry
        let selectedGap = tabBarLayout.selectedSeparatorGap(
            selectedTabFrame: selectedTabFrameInBar,
            totalWidth: totalWidth
        )
        if let maskFrame = geometry.fallbackSeparatorMaskFrame(
            totalWidth: totalWidth,
            height: tabBarHeight,
            selectedSeparatorGap: selectedGap
        ) {
            ZStack(alignment: .topLeading) {
                let fadeFrame = geometry.separatorFadeFrame(totalWidth: totalWidth, height: tabBarHeight)
                if fadeFrame.width > 0 {
                    splitButtonSeparatorFadeSegment(snapshot: snapshot)
                        .frame(width: fadeFrame.width, height: fadeFrame.height)
                        .offset(x: fadeFrame.minX, y: fadeFrame.minY)
                }
                let solidFrame = geometry.separatorSolidFrame(totalWidth: totalWidth, height: tabBarHeight)
                if solidFrame.width > 0 {
                    Rectangle()
                        .fill(TabBarColors.separator(for: appearance))
                        .frame(width: solidFrame.width, height: solidFrame.height)
                        .offset(x: solidFrame.minX, y: solidFrame.minY)
                }
            }
            .frame(width: totalWidth, height: tabBarHeight, alignment: .topLeading)
            .mask(alignment: .topLeading) {
                Rectangle()
                    .frame(width: maskFrame.width, height: maskFrame.height)
                    .offset(x: maskFrame.minX, y: maskFrame.minY)
            }
        }
    }

    @ViewBuilder
    private func splitButtonSeparatorFadeSegment(snapshot: TabBarChromeSnapshot) -> some View {
        let separator = TabBarColors.separator(for: appearance)
        let rampStart = snapshot.backdropFadeRampStartFraction
        LinearGradient(
            stops: [
                .init(color: separator.opacity(0), location: 0),
                .init(color: separator.opacity(0), location: rampStart),
                .init(color: separator, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    @ViewBuilder
    private var splitButtons: some View {
        let laneWidth = splitButtonsBackdropWidth
        ZStack(alignment: .trailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                splitButtonRow
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: laneWidth, alignment: .trailing)
                    .background(SplitButtonLaneWidthReader())
                    .background(
                        GeometryReader { contentGeo in
                            Color.clear
                                .onChange(
                                    of: contentGeo.frame(in: .named(splitButtonScrollCoordinateSpaceName))
                                ) { _, newFrame in
                                    updateSplitButtonScrollContent(frame: newFrame)
                                }
                                .onAppear {
                                    updateSplitButtonScrollContent(
                                        frame: contentGeo.frame(in: .named(splitButtonScrollCoordinateSpaceName))
                                    )
                                }
                        }
                    )
            }
            .coordinateSpace(name: splitButtonScrollCoordinateSpaceName)
            .frame(width: laneWidth, height: tabBarHeight, alignment: .trailing)
            .background(
                GeometryReader { viewportGeo in
                    Color.clear
                        .onChange(of: viewportGeo.size.width) { _, newWidth in
                            splitButtonViewportWidth = newWidth
                        }
                        .onAppear {
                            splitButtonViewportWidth = viewportGeo.size.width
                        }
                }
            )
            .mask(
                splitButtonScrollMask
                    .frame(width: laneWidth, height: tabBarHeight)
            )
        }
        .frame(width: laneWidth, height: tabBarHeight, alignment: .trailing)
        .contentShape(Rectangle())
        .clipped()
    }

    @ViewBuilder
    private var splitButtonScrollMask: some View {
        let affordances = splitButtonScrollAffordances
        let fadeWidth = TabBarStyling.splitButtonScrollFadeWidth
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: affordances.left ? fadeWidth : 0, height: tabBarHeight)
            Rectangle().fill(Color.black)
                .frame(height: tabBarHeight)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: affordances.right ? fadeWidth : 0, height: tabBarHeight)
        }
        .frame(height: tabBarHeight)
    }

    private func updateSplitButtonScrollContent(frame: CGRect) {
        splitButtonScrollOffset = max(0, -frame.minX)
        splitButtonContentWidth = frame.width
    }

    @ViewBuilder
    private var splitButtonRow: some View {
        let tooltips = controller.configuration.appearance.splitButtonTooltips
        let buttons = visibleSplitButtons
        HStack(spacing: TabBarStyling.splitButtonsSpacing) {
            ForEach(buttons.indices, id: \.self) { index in
                let button = buttons[index]
                Button {
                    performSplitActionButton(button)
                } label: {
                    splitActionButtonIcon(button.icon)
                }
                .buttonStyle(SplitActionButtonStyle(appearance: appearance, layout: tabBarLayout))
                .accessibilityIdentifier(splitActionButtonAccessibilityIdentifier(button))
                .safeHelp(splitActionButtonTooltip(button, tooltips: tooltips))
            }
        }
        .padding(.leading, TabBarStyling.splitButtonsLeadingPadding)
        .padding(.trailing, TabBarStyling.splitButtonsTrailingPadding)
        .frame(height: tabBarHeight, alignment: .center)
    }

    private func splitActionButtonAccessibilityIdentifier(_ button: WorkspaceLayoutConfiguration.SplitActionButton) -> String {
        switch button.action {
        case .newTerminal:
            return "paneTabBarControl.newTerminal"
        case .newBrowser:
            return "paneTabBarControl.newBrowser"
        case .splitRight:
            return "paneTabBarControl.splitRight"
        case .splitDown:
            return "paneTabBarControl.splitDown"
        case .custom(let identifier):
            return "paneTabBarControl.custom.\(identifier)"
        }
    }

    @ViewBuilder
    private func splitActionButtonIcon(_ icon: WorkspaceLayoutConfiguration.SplitActionButton.Icon) -> some View {
        switch icon {
        case .systemImage(let name):
            Image(systemName: name)
                .font(.system(size: 12))
        case .emoji(let value, let scale):
            Text(value)
                .font(.system(size: emojiIconFontSize(scale: scale)))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        case .imageData(let data):
            if let image = splitActionButtonImage(from: data) {
                Image(nsImage: image)
                    .renderingMode(image.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
            }
        }
    }

    private func emojiIconFontSize(scale: Double) -> CGFloat {
        let safeScale: CGFloat
        if scale.isFinite, scale > 0 {
            safeScale = CGFloat(scale)
        } else {
            safeScale = 1
        }
        return 13 * safeScale
    }

    private func splitActionButtonImage(from data: Data) -> NSImage? {
        TabBarStyling.splitActionButtonImage(from: data)
    }

    private func splitActionButtonTooltip(
        _ button: WorkspaceLayoutConfiguration.SplitActionButton,
        tooltips: WorkspaceLayoutConfiguration.SplitButtonTooltips
    ) -> String {
        if let tooltip = button.tooltip?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tooltip.isEmpty {
            return tooltip
        }

        switch button.action {
        case .newTerminal:
            return tooltips.newTerminal
        case .newBrowser:
            return tooltips.newBrowser
        case .splitRight:
            return tooltips.splitRight
        case .splitDown:
            return tooltips.splitDown
        case .custom(let identifier):
            return identifier
        }
    }

    private func performSplitActionButton(_ button: WorkspaceLayoutConfiguration.SplitActionButton) {
        guard splitViewController.isInteractive else { return }

        switch button.action {
        case .newTerminal:
            controller.requestNewTab(kind: "terminal", inPane: pane.id)
        case .newBrowser:
            controller.requestNewTab(kind: "browser", inPane: pane.id)
        case .splitRight:
            // 120fps animation handled by SplitAnimator
            controller.splitPane(pane.id, orientation: .horizontal)
        case .splitDown:
            // 120fps animation handled by SplitAnimator
            controller.splitPane(pane.id, orientation: .vertical)
        case .custom(let identifier):
            controller.requestCustomAction(identifier, inPane: pane.id)
        }
    }

    private func performNewTerminalSplitButtonAction() -> Bool {
        guard splitViewController.isInteractive else { return false }
        guard let button = visibleSplitButtons.first(where: { $0.action == .newTerminal }) else {
            return false
        }
        performSplitActionButton(button)
        return true
    }


    // MARK: - Combined Mask (scroll fades + button area)
    //
    // The split-button backdrop is responsible for occluding content under the controls.
    // When enabled, tab content fades out before the backdrop ramp starts. This keeps the
    // transparent start of the backdrop fade from blending over bright tab text/icons.

    @ViewBuilder
    private var combinedMask: some View {
        let fadeWidth: CGFloat = 24
        let snapshot = chromeSnapshot
        HStack(spacing: 0) {
            // Left scroll fade
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: canScrollLeft ? fadeWidth : 0, height: tabBarHeight)

            // Visible content area (always opaque so hit testing reaches the tabs)
            Rectangle().fill(Color.black)
                .frame(height: tabBarHeight)

            if snapshot.masksTabContentUnderActionLane {
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: snapshot.contentFadeWidth, height: tabBarHeight)
                // Action-lane content is always fully removed from the tab layer.
                // Backdrop softness belongs to the foreground chrome snapshot, not the mask width.
                Color.clear
                    .frame(width: snapshot.contentOcclusionWidth, height: tabBarHeight)
            } else {
                // Right scroll fade only when scroll content actually overflows.
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: canScrollRight ? fadeWidth : 0, height: tabBarHeight)
            }
        }
        .frame(height: tabBarHeight)
    }

    // MARK: - Chrome

    @ViewBuilder
    private var tabBarSurface: some View {
        TabBarLayerBackedColor(color: chromeSnapshot.barColor)
            .frame(maxWidth: .infinity)
            .frame(height: tabBarHeight)
    }

    @ViewBuilder
    private var maskedSelectedTabIndicatorChrome: some View {
        GeometryReader { geometry in
            selectedTabIndicator(totalWidth: geometry.size.width)
                .frame(width: geometry.size.width, height: tabBarHeight, alignment: .topLeading)
                .mask(combinedMask)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var maskedTabBarBottomSeparatorChrome: some View {
        GeometryReader { geometry in
            tabBarBottomSeparator(totalWidth: geometry.size.width)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func selectedTabIndicator(totalWidth: CGFloat) -> some View {
        if let frame = selectedIndicatorFrame(totalWidth: totalWidth) {
            Rectangle()
                .fill(TabBarColors.activeIndicator(saturation: tabBarSaturation))
                .frame(width: frame.width, height: TabBarMetrics.activeIndicatorHeight)
                .offset(x: frame.minX)
        }
    }

    @ViewBuilder
    private func tabBarBottomSeparator(totalWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                let separator = TabBarColors.separator(for: appearance)
                let gapRange = tabBarLayout.selectedSeparatorGap(
                    selectedTabFrame: selectedTabFrameInBar,
                    totalWidth: totalWidth
                )
                let segments = TabBarStyling.separatorSegments(
                    totalWidth: totalWidth,
                    gap: gapRange
                )
                Rectangle()
                    .fill(separator)
                    .frame(width: segments.left, height: 1)
                Spacer(minLength: 0)
                Rectangle()
                    .fill(separator)
                    .frame(width: segments.right, height: 1)
            }
        }
    }

    private func selectedIndicatorFrame(totalWidth: CGFloat) -> CGRect? {
        tabBarLayout.selectedIndicatorFrame(
            selectedTabFrame: selectedTabFrameInBar,
            totalWidth: totalWidth
        )
    }
}

private struct TabBarLayerBackedColor: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context _: Context) -> NSView {
        let view = View()
        view.setColor(color)
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        (nsView as? View)?.setColor(color)
    }

    private final class View: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        override var isOpaque: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        private func setup() {
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.isOpaque = false
        }

        func setColor(_ color: NSColor) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.backgroundColor = color.cgColor
            layer?.isOpaque = color.alphaComponent >= 1
            CATransaction.commit()
        }
    }
}

private final class SplitActionButtonImageCache {
    static let shared = SplitActionButtonImageCache()

    private let images = NSCache<NSData, NSImage>()
    private let invalidImageData = NSCache<NSData, NSNumber>()

    private init() {
        images.countLimit = 128
        images.totalCostLimit = 8 * 1024 * 1024
        invalidImageData.countLimit = 256
        invalidImageData.totalCostLimit = 512 * 1024
    }

    func image(for data: Data) -> NSImage? {
        let key = data as NSData
        if let image = images.object(forKey: key) {
            return image
        }
        if invalidImageData.object(forKey: key) != nil {
            return nil
        }

        guard let image = NSImage(data: data) else {
            invalidImageData.setObject(
                NSNumber(value: true),
                forKey: key,
                cost: max(1, min(data.count, 1024))
            )
            return nil
        }
        image.isTemplate = TabBarStyling.imageDataShouldRenderAsTemplate(data)

        images.setObject(image, forKey: key, cost: max(1, data.count))
        return image
    }
}

private struct SplitActionButtonStyle: ButtonStyle {
    let appearance: WorkspaceLayoutConfiguration.Appearance
    let layout: TabBarLayout

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(height: layout.splitActionButtonHeight)
            .contentShape(Rectangle())
            .foregroundStyle(TabBarColors.splitActionIcon(for: appearance, isPressed: configuration.isPressed))
            .opacity(configuration.isPressed ? 0.72 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct TabBarHoverTrackingView: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HoverNSView {
        let view = HoverNSView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: HoverNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }

    final class HoverNSView: NSView {
        var onHoverChanged: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var localMouseMonitor: Any?
        private var isHovering = false

        deinit {
            removeLocalMouseMonitor()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.acceptsMouseMovedEvents = true
                installLocalMouseMonitorIfNeeded()
                updateHoverFromCurrentMouseLocation()
            } else {
                removeLocalMouseMonitor()
                emitHoverChanged(false)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            updateHover(from: event)
        }

        override func mouseExited(with event: NSEvent) {
            updateHover(from: event)
        }

        override func mouseMoved(with event: NSEvent) {
            updateHover(from: event)
        }

        private func installLocalMouseMonitorIfNeeded() {
            guard localMouseMonitor == nil else { return }
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseDragged]
            ) { [weak self] event in
                self?.updateHover(from: event)
                return event
            }
        }

        private func removeLocalMouseMonitor() {
            if let localMouseMonitor {
                NSEvent.removeMonitor(localMouseMonitor)
                self.localMouseMonitor = nil
            }
        }

        private func updateHover(from event: NSEvent) {
            guard let window else {
                emitHoverChanged(false)
                return
            }
            guard event.window == nil || event.window === window else {
                emitHoverChanged(false)
                return
            }

            let pointInWindow = event.window === window
                ? event.locationInWindow
                : window.mouseLocationOutsideOfEventStream
            let pointInView = convert(pointInWindow, from: nil)
            emitHoverChanged(bounds.insetBy(dx: -1, dy: -1).contains(pointInView))
        }

        private func updateHoverFromCurrentMouseLocation() {
            guard let window else {
                emitHoverChanged(false)
                return
            }
            let pointInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            emitHoverChanged(bounds.insetBy(dx: -1, dy: -1).contains(pointInView))
        }

        private func emitHoverChanged(_ newValue: Bool) {
            guard isHovering != newValue else { return }
            isHovering = newValue
            onHoverChanged?(newValue)
        }
    }
}

private struct TabBarManualReorderTrackingView: NSViewRepresentable {
    let pane: PaneState
    let layoutController: WorkspaceLayoutController
    let splitViewController: SplitViewController
    let tabFrames: [UUID: CGRect]
    @Binding var dropTargetIndex: Int?
    @Binding var dropLifecycle: TabDropLifecycle

    func makeNSView(context: Context) -> ManualReorderNSView {
        let view = ManualReorderNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: ManualReorderNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: ManualReorderNSView) {
        view.pane = pane
        view.layoutController = layoutController
        view.splitViewController = splitViewController
        view.tabFrames = tabFrames
        view.onDropStateChanged = { targetIndex, lifecycle in
            dropTargetIndex = targetIndex
            dropLifecycle = lifecycle
        }
    }

    final class ManualReorderNSView: NSView {
        weak var pane: PaneState?
        weak var layoutController: WorkspaceLayoutController?
        weak var splitViewController: SplitViewController?
        var tabFrames: [UUID: CGRect] = [:]
        var onDropStateChanged: ((Int?, TabDropLifecycle) -> Void)?

        private var localMouseMonitor: Any?
        private var session: ManualDragSession?

        private static let dragStartDistanceSquared: CGFloat = 16
        private static let trailingDropSlop: CGFloat = 30

        override var mouseDownCanMoveWindow: Bool { false }

        deinit {
            removeLocalMouseMonitor()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installLocalMouseMonitorIfNeeded()
            } else {
                removeLocalMouseMonitor()
                clearManualDrag()
            }
        }

        private func installLocalMouseMonitorIfNeeded() {
            guard localMouseMonitor == nil else { return }
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func removeLocalMouseMonitor() {
            if let localMouseMonitor {
                NSEvent.removeMonitor(localMouseMonitor)
                self.localMouseMonitor = nil
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window else {
                clearManualDrag()
                return
            }
            guard event.window == nil || event.window === window else {
                if session != nil {
                    clearManualDrag()
                }
                return
            }

            let windowPoint = event.window === window
                ? event.locationInWindow
                : window.mouseLocationOutsideOfEventStream
            let point = convert(windowPoint, from: nil)

            switch event.type {
            case .leftMouseDown:
                beginTrackingIfNeeded(at: point)
            case .leftMouseDragged:
                updateTracking(at: point)
            case .leftMouseUp:
                finishTracking()
            default:
                break
            }
        }

        private func beginTrackingIfNeeded(at point: NSPoint) {
            guard bounds.contains(point),
                  let pane,
                  let splitViewController,
                  splitViewController.isInteractive,
                  let source = tab(at: point, in: pane) else {
                clearManualDrag()
                return
            }

            session = ManualDragSession(
                sourceTab: source,
                sourcePaneId: pane.id,
                startPoint: point,
                currentTargetIndex: nil,
                didStartDrag: false
            )
        }

        private func updateTracking(at point: NSPoint) {
            guard var session else { return }

            let dx = point.x - session.startPoint.x
            let dy = point.y - session.startPoint.y
            if !session.didStartDrag {
                guard dx * dx + dy * dy >= Self.dragStartDistanceSquared else { return }
                beginManualDrag(for: session)
                session.didStartDrag = true
            }

            let targetIndex = dropTargetIndex(at: point)
            session.currentTargetIndex = targetIndex
            self.session = session

            if let targetIndex,
               !shouldSuppressIndicator(sourceTabId: session.sourceTab.id, targetIndex: targetIndex) {
                onDropStateChanged?(targetIndex, .hovering)
            } else {
                onDropStateChanged?(nil, .idle)
            }
        }

        private func finishTracking() {
            guard let session else {
                clearManualDrag()
                return
            }

            defer {
                clearControllerDragStateIfNeeded(sourceTabId: session.sourceTab.id)
                clearManualDrag()
            }

            guard session.didStartDrag,
                  let pane,
                  let layoutController,
                  let targetIndex = session.currentTargetIndex,
                  !shouldSuppressIndicator(sourceTabId: session.sourceTab.id, targetIndex: targetIndex),
                  let currentSourceIndex = pane.tabs.firstIndex(where: { $0.id == session.sourceTab.id }) else {
                return
            }

            withTransaction(Transaction(animation: nil)) {
                pane.moveTab(from: currentSourceIndex, to: targetIndex)
                layoutController.focusPane(pane.id)
            }
        }

        private func beginManualDrag(for session: ManualDragSession) {
            guard let splitViewController else { return }
#if DEBUG
            dlog(
                "tab.manualDragStart pane=\(session.sourcePaneId.id.uuidString.prefix(5)) " +
                    "tab=\(session.sourceTab.id.uuidString.prefix(5)) title=\"\(session.sourceTab.title)\""
            )
#endif
            splitViewController.dragGeneration += 1
            splitViewController.draggingTab = session.sourceTab
            splitViewController.dragSourcePaneId = session.sourcePaneId
            splitViewController.activeDragTab = session.sourceTab
            splitViewController.activeDragSourcePaneId = session.sourcePaneId
        }

        private func clearManualDrag() {
            session = nil
            onDropStateChanged?(nil, .idle)
        }

        private func clearControllerDragStateIfNeeded(sourceTabId: UUID) {
            guard let splitViewController else { return }
            if splitViewController.draggingTab?.id == sourceTabId {
                splitViewController.draggingTab = nil
                splitViewController.dragSourcePaneId = nil
            }
            if splitViewController.activeDragTab?.id == sourceTabId {
                splitViewController.activeDragTab = nil
                splitViewController.activeDragSourcePaneId = nil
            }
        }

        private func tab(at point: NSPoint, in pane: PaneState) -> SurfaceItem? {
            for tab in pane.tabs {
                guard let frame = tabFrames[tab.id] else { continue }
                if point.x >= frame.minX, point.x <= frame.maxX {
                    return tab
                }
            }
            return nil
        }

        private func dropTargetIndex(at point: NSPoint) -> Int? {
            guard bounds.insetBy(dx: 0, dy: -4).contains(point),
                  let pane,
                  !pane.tabs.isEmpty else {
                return nil
            }

            var lastFrame: CGRect?
            for (index, tab) in pane.tabs.enumerated() {
                guard let frame = tabFrames[tab.id] else { continue }
                lastFrame = frame
                if point.x < frame.midX {
                    return index
                }
            }

            if let lastFrame,
               point.x <= lastFrame.maxX + Self.trailingDropSlop {
                return pane.tabs.count
            }
            return nil
        }

        private func shouldSuppressIndicator(sourceTabId: UUID, targetIndex: Int) -> Bool {
            guard let pane,
                  let sourceIndex = pane.tabs.firstIndex(where: { $0.id == sourceTabId }) else {
                return false
            }
            return targetIndex == sourceIndex || targetIndex == sourceIndex + 1
        }

        private struct ManualDragSession {
            let sourceTab: SurfaceItem
            let sourcePaneId: PaneID
            let startPoint: NSPoint
            var currentTargetIndex: Int?
            var didStartDrag: Bool
        }
    }
}

/// Background view that provides window-drag-from-empty-space in minimal mode
/// and hover tracking via NSTrackingArea (replacing .contentShape + .onHover).
/// As a .background(), AppKit routes clicks to tabs/buttons in front first;
/// this view only receives hits in truly empty space.
private struct TabBarDragAndHoverView: NSViewRepresentable {
    let isMinimalMode: Bool
    let onDoubleClick: () -> Bool
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> TabBarBackgroundNSView {
        let view = TabBarBackgroundNSView()
        view.isMinimalMode = isMinimalMode
        view.onDoubleClick = onDoubleClick
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: TabBarBackgroundNSView, context: Context) {
        nsView.isMinimalMode = isMinimalMode
        nsView.onDoubleClick = onDoubleClick
        nsView.onHoverChanged = onHoverChanged
    }

    final class TabBarBackgroundNSView: NSView {
        var isMinimalMode = false
        var onDoubleClick: (() -> Bool)?
        var onHoverChanged: ((Bool) -> Void)?
        private var hoverTrackingArea: NSTrackingArea?
        private var windowDidBecomeKeyObserver: NSObjectProtocol?
        private var windowDidResignKeyObserver: NSObjectProtocol?
        private var localMouseMonitor: Any?
        private var isHovering = false

        override var mouseDownCanMoveWindow: Bool { false }

        deinit {
            removeLocalMouseMonitor()
            removeWindowObservers()
            WorkspaceLayoutTabBarHitRegionRegistry.unregister(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            WorkspaceLayoutTabBarHitRegionRegistry.unregister(self)
            removeWindowObservers()
            if let window {
                window.acceptsMouseMovedEvents = true
                WorkspaceLayoutTabBarHitRegionRegistry.register(self)
                installWindowObservers()
                installLocalMouseMonitorIfNeeded()
                syncHoverStateToCurrentMouseLocation()
            } else {
                removeLocalMouseMonitor()
                emitHoverChanged(false)
            }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            if superview == nil {
                WorkspaceLayoutTabBarHitRegionRegistry.unregister(self)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = hoverTrackingArea {
                removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            emitHoverChanged(true)
        }

        override func mouseExited(with event: NSEvent) {
            emitHoverChanged(false)
        }

        override func mouseMoved(with event: NSEvent) {
            updateHover(from: event)
        }

        override func mouseDown(with event: NSEvent) {
#if DEBUG
            dlog("tab.bar.bg.mouseDown isMinimal=\(isMinimalMode ? 1 : 0) clickCount=\(event.clickCount)")
#endif
            guard let window else {
                super.mouseDown(with: event)
                return
            }
            if event.clickCount >= 2 {
                if isMinimalMode {
                    let action = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
                    switch action {
                    case "Minimize": window.miniaturize(nil)
                    default: window.zoom(nil)
                    }
                    return
                }
                if onDoubleClick?() == true {
                    return
                }
            }
            guard isMinimalMode else {
                super.mouseDown(with: event)
                return
            }
            let wasMovable = window.isMovable
            window.isMovable = true
            window.performDrag(with: event)
            window.isMovable = wasMovable
        }

        func syncHoverStateToCurrentMouseLocation() {
            guard let window else {
                emitHoverChanged(false)
                return
            }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            emitHoverChanged(bounds.contains(point))
        }

        private func installLocalMouseMonitorIfNeeded() {
            guard localMouseMonitor == nil else { return }
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseDragged]
            ) { [weak self] event in
                self?.updateHover(from: event)
                return event
            }
        }

        private func removeLocalMouseMonitor() {
            if let localMouseMonitor {
                NSEvent.removeMonitor(localMouseMonitor)
                self.localMouseMonitor = nil
            }
        }

        private func updateHover(from event: NSEvent) {
            guard let window else {
                emitHoverChanged(false)
                return
            }
            guard event.window == nil || event.window === window else {
                emitHoverChanged(false)
                return
            }

            let pointInWindow = event.window === window
                ? event.locationInWindow
                : window.mouseLocationOutsideOfEventStream
            let pointInView = convert(pointInWindow, from: nil)
            emitHoverChanged(bounds.insetBy(dx: -1, dy: -1).contains(pointInView))
        }

        private func emitHoverChanged(_ newValue: Bool) {
            guard isHovering != newValue else { return }
            isHovering = newValue
            onHoverChanged?(newValue)
        }

        private func installWindowObservers() {
            guard let window else { return }
            windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.syncHoverStateToCurrentMouseLocation()
            }
            windowDidResignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.syncHoverStateToCurrentMouseLocation()
            }
        }

        private func removeWindowObservers() {
            if let windowDidBecomeKeyObserver {
                NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
                self.windowDidBecomeKeyObserver = nil
            }
            if let windowDidResignKeyObserver {
                NotificationCenter.default.removeObserver(windowDidResignKeyObserver)
                self.windowDidResignKeyObserver = nil
            }
        }
    }
}

struct TabBarDragZoneView: NSViewRepresentable {
    enum HitRegion {
        case entireBounds
        case trailingEmptyChrome(tabFrames: [CGRect], reservedTrailingWidth: CGFloat)
    }

    var hitRegion: HitRegion = .entireBounds
    let isMinimalMode: Bool
    let isFocusedPane: Bool
    let onSingleClick: () -> Bool
    let onDoubleClick: () -> Bool

    func makeNSView(context: Context) -> DragNSView {
        let view = DragNSView()
        view.hitRegion = hitRegion
        view.isMinimalMode = isMinimalMode
        view.isFocusedPane = isFocusedPane
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: DragNSView, context: Context) {
        nsView.hitRegion = hitRegion
        nsView.isMinimalMode = isMinimalMode
        nsView.isFocusedPane = isFocusedPane
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }

    final class DragNSView: NSView {
        var hitRegion = HitRegion.entireBounds
        var hitTestEventTypeOverride: NSEvent.EventType?
        var isMinimalMode = false
        var isFocusedPane = false
        var onSingleClick: (() -> Bool)?
        var onDoubleClick: (() -> Bool)?
        var performWindowDrag: ((NSEvent) -> Bool)?
        private var pendingWindowDragEvent: NSEvent?
        private var pendingWindowDragStart: NSPoint?

        private static let windowDragStartDistanceSquared: CGFloat = 16

        // Must stay false so AppKit does not intercept mouseUp as part of its
        // own window-drag tracking. When AppKit steals mouseUp from the first
        // click, the second click of a double-click is registered as a fresh
        // clickCount=1 instead of 2, making new-tab double-clicks flaky. We
        // still support window dragging via the custom mouseDragged →
        // window.performDrag flow below. See `NonDraggableHostingView` in
        // SplitNodeView.swift for the same class of bug on pane tab clicks.
        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard shouldCaptureHit(at: point) else { return nil }
            return self
        }

        override func mouseDown(with event: NSEvent) {
#if DEBUG
            let point = convert(event.locationInWindow, from: nil)
            dlog(
                "tab.bar.dragZone.mouseDown isMinimal=\(isMinimalMode ? 1 : 0) " +
                "focused=\(isFocusedPane ? 1 : 0) clickCount=\(event.clickCount) " +
                "point=\(point.x.rounded()),\(point.y.rounded()) " +
                "bounds=\(bounds.width.rounded())x\(bounds.height.rounded())"
            )
#endif
            guard let window = self.window else {
                super.mouseDown(with: event)
                return
            }

            if !isMinimalMode {
                clearPendingWindowDrag()
                if event.clickCount == 1 {
                    if !isFocusedPane, onSingleClick?() == true {
#if DEBUG
                        dlog("tab.bar.dragZone.focusPane")
#endif
                    } else {
#if DEBUG
                        dlog("tab.bar.dragZone.click skipped reason=standardSingleClick clickCount=\(event.clickCount)")
#endif
                    }
                    return
                }
                if event.clickCount >= 2 {
                    if onDoubleClick?() == true {
#if DEBUG
                        dlog("tab.bar.dragZone.doubleClick action=newTab")
#endif
                        return
                    }
                }
#if DEBUG
                dlog("tab.bar.dragZone.click skipped reason=standardUnhandledClick clickCount=\(event.clickCount)")
#endif
                return
            }

            if event.clickCount >= 2 {
                clearPendingWindowDrag()
#if DEBUG
                dlog("tab.bar.dragZone.doubleClick action=titlebar")
#endif
                performTitlebarDoubleClickAction(in: window)
                return
            }

            if !isFocusedPane, onSingleClick?() == true {
                clearPendingWindowDrag()
#if DEBUG
                dlog("tab.bar.dragZone.focusPane")
#endif
                return
            }

            pendingWindowDragEvent = event
            pendingWindowDragStart = event.locationInWindow
        }

        private func shouldCaptureHit(at point: NSPoint) -> Bool {
            guard bounds.contains(point) else { return false }
            switch hitRegion {
            case .entireBounds:
                return true
            case .trailingEmptyChrome(let tabFrames, let reservedTrailingWidth):
                guard isMouseDownOrDragCandidate else { return false }
                let trailingLimit = bounds.maxX - max(0, reservedTrailingWidth)
                guard point.x < trailingLimit else { return false }
                let paddedFrames = tabFrames.map { $0.insetBy(dx: -2, dy: -2) }
                guard !paddedFrames.contains(where: { $0.contains(point) }) else { return false }
                let startX = paddedFrames.map(\.maxX).max() ?? bounds.minX
                return point.x >= startX
            }
        }

        private var isMouseDownOrDragCandidate: Bool {
            switch hitTestEventTypeOverride ?? NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
                return true
            default:
                return false
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard isMinimalMode,
                  let window,
                  let pendingEvent = pendingWindowDragEvent,
                  let start = pendingWindowDragStart else {
                super.mouseDragged(with: event)
                return
            }

            let dx = event.locationInWindow.x - start.x
            let dy = event.locationInWindow.y - start.y
            guard dx * dx + dy * dy >= Self.windowDragStartDistanceSquared else {
                return
            }

#if DEBUG
            dlog(
                "tab.bar.dragZone.dragStart " +
                "dx=\(dx.rounded()) dy=\(dy.rounded())"
            )
#endif
            clearPendingWindowDrag()
            startWindowDrag(with: pendingEvent, in: window)
        }

        override func mouseUp(with event: NSEvent) {
            clearPendingWindowDrag()
            super.mouseUp(with: event)
        }

        private func clearPendingWindowDrag() {
            pendingWindowDragEvent = nil
            pendingWindowDragStart = nil
        }

        private func startWindowDrag(with event: NSEvent, in window: NSWindow) {
            if let performWindowDrag, performWindowDrag(event) {
#if DEBUG
                dlog("tab.bar.dragZone.dragStart action=testHook")
#endif
                return
            }
            let wasMovable = window.isMovable
            window.isMovable = true
            defer { window.isMovable = wasMovable }
            window.performDrag(with: event)
#if DEBUG
            dlog("tab.bar.dragZone.dragStart action=windowPerformDrag")
#endif
        }

        private func performTitlebarDoubleClickAction(in window: NSWindow) {
            let action = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
            switch action {
            case "Minimize": window.miniaturize(nil)
            default: window.zoom(nil)
            }
        }
    }
}

private struct TabBarScrollViewResolver: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveScrollView()
    }

    final class ResolverView: NSView {
        var onResolve: ((NSScrollView?) -> Void)?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            resolveScrollView()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveScrollView()
        }

        override func layout() {
            super.layout()
            resolveScrollView()
        }

        func resolveScrollView() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let scrollView = self.enclosingScrollView
                self.makeScrollStackTransparent(scrollView)
                onResolve?(scrollView)
            }
        }

        private func makeScrollStackTransparent(_ scrollView: NSScrollView?) {
            scrollView?.drawsBackground = false
            scrollView?.backgroundColor = .clear
            scrollView?.wantsLayer = true
            scrollView?.layer?.backgroundColor = NSColor.clear.cgColor
            scrollView?.layer?.isOpaque = false

            let clipView = scrollView?.contentView
            clipView?.drawsBackground = false
            clipView?.backgroundColor = .clear
            clipView?.wantsLayer = true
            clipView?.layer?.backgroundColor = NSColor.clear.cgColor
            clipView?.layer?.isOpaque = false

            scrollView?.documentView?.wantsLayer = true
            scrollView?.documentView?.layer?.backgroundColor = NSColor.clear.cgColor
            scrollView?.documentView?.layer?.isOpaque = false
        }
    }
}

private struct TabControlShortcutStoredShortcut: Decodable {
    let key: String
    let command: Bool
    let shift: Bool
    let option: Bool
    let control: Bool

    init(
        key: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    var modifierSymbol: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        return parts.joined()
    }
}

private enum TabControlShortcutSettings {
    static let surfaceByNumberKey = "shortcut.selectSurfaceByNumber"
    static let defaultShortcut = TabControlShortcutStoredShortcut(
        key: "1",
        command: false,
        shift: false,
        option: false,
        control: true
    )

    static func surfaceByNumberShortcut(defaults: UserDefaults = .standard) -> TabControlShortcutStoredShortcut {
        guard let data = defaults.data(forKey: surfaceByNumberKey),
              let shortcut = try? JSONDecoder().decode(TabControlShortcutStoredShortcut.self, from: data) else {
            return defaultShortcut
        }
        return shortcut
    }
}

struct TabControlShortcutModifier: Equatable {
    let modifierFlags: NSEvent.ModifierFlags
    let symbol: String
}

enum TabControlShortcutHintPolicy {
    static let intentionalHoldDelay: TimeInterval = 0.30
    static let showHintsOnCommandHoldKey = "shortcutHintShowOnCommandHold"
    static let showHintsOnControlHoldKey = "shortcutHintShowOnControlHold"
    static let defaultShowHintsOnCommandHold = true
    static let defaultShowHintsOnControlHold = true

    static func showHintsOnCommandHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showHintsOnCommandHoldKey) != nil else {
            return defaultShowHintsOnCommandHold
        }
        return defaults.bool(forKey: showHintsOnCommandHoldKey)
    }

    static func showHintsOnControlHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showHintsOnControlHoldKey) != nil else {
            return defaultShowHintsOnControlHold
        }
        return defaults.bool(forKey: showHintsOnControlHoldKey)
    }

    private static func triggerAllowsHintReveal(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        switch flags {
        case [.command]:
            return showHintsOnCommandHoldEnabled(defaults: defaults)
        case [.control]:
            return showHintsOnControlHoldEnabled(defaults: defaults)
        default:
            return false
        }
    }

    static func hintModifier(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> TabControlShortcutModifier? {
        guard triggerAllowsHintReveal(for: modifierFlags, defaults: defaults) else { return nil }
        let shortcut = TabControlShortcutSettings.surfaceByNumberShortcut(defaults: defaults)
        return TabControlShortcutModifier(
            modifierFlags: shortcut.modifierFlags,
            symbol: shortcut.modifierSymbol
        )
    }

    static func isCurrentWindow(
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?
    ) -> Bool {
        guard let hostWindowNumber, hostWindowIsKey else { return false }
        if let eventWindowNumber {
            return eventWindowNumber == hostWindowNumber
        }
        return keyWindowNumber == hostWindowNumber
    }

    static func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        triggerAllowsHintReveal(for: modifierFlags, defaults: defaults) &&
            isCurrentWindow(
                hostWindowNumber: hostWindowNumber,
                hostWindowIsKey: hostWindowIsKey,
                eventWindowNumber: eventWindowNumber,
                keyWindowNumber: keyWindowNumber
            )
    }
}

private struct TabBarHostWindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            onResolve(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            onResolve(nsView?.window)
        }
    }
}

@MainActor
private final class TabControlShortcutKeyMonitor: ObservableObject {
    @Published private(set) var isShortcutHintVisible = false
    @Published private(set) var shortcutModifierSymbol = "⌃"

    private weak var hostWindow: NSWindow?
    private var hostWindowDidBecomeKeyObserver: NSObjectProtocol?
    private var hostWindowDidResignKeyObserver: NSObjectProtocol?
    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var pendingShowWorkItem: DispatchWorkItem?
    private var pendingModifier: TabControlShortcutModifier?

    func setHostWindow(_ window: NSWindow?) {
        guard hostWindow !== window else { return }
        removeHostWindowObservers()
        hostWindow = window
        guard let window else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        hostWindowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.update(from: NSEvent.modifierFlags, eventWindow: nil)
            }
        }

        hostWindowDidResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func start() {
        guard flagsMonitor == nil else {
            update(from: NSEvent.modifierFlags, eventWindow: nil)
            return
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(from: event.modifierFlags, eventWindow: event.window)
            return event
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.isCurrentWindow(eventWindow: event.window) == true else { return event }
            self?.cancelPendingHintShow(resetVisible: true)
            return event
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func stop() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        removeHostWindowObservers()
        cancelPendingHintShow(resetVisible: true)
    }

    private func isCurrentWindow(eventWindow: NSWindow?) -> Bool {
        TabControlShortcutHintPolicy.isCurrentWindow(
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        )
    }

    private func update(from modifierFlags: NSEvent.ModifierFlags, eventWindow: NSWindow?) {
        guard TabControlShortcutHintPolicy.shouldShowHints(
            for: modifierFlags,
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        ) else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        guard let modifier = TabControlShortcutHintPolicy.hintModifier(for: modifierFlags) else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        if isShortcutHintVisible {
            shortcutModifierSymbol = modifier.symbol
            return
        }

        queueHintShow(for: modifier)
    }

    private func queueHintShow(for modifier: TabControlShortcutModifier) {
        if pendingModifier == modifier, pendingShowWorkItem != nil {
            return
        }

        pendingShowWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShowWorkItem = nil
            self.pendingModifier = nil
            guard TabControlShortcutHintPolicy.shouldShowHints(
                for: NSEvent.modifierFlags,
                hostWindowNumber: self.hostWindow?.windowNumber,
                hostWindowIsKey: self.hostWindow?.isKeyWindow ?? false,
                eventWindowNumber: nil,
                keyWindowNumber: NSApp.keyWindow?.windowNumber
            ) else { return }
            guard let currentModifier = TabControlShortcutHintPolicy.hintModifier(for: NSEvent.modifierFlags) else { return }
            self.shortcutModifierSymbol = currentModifier.symbol
            withAnimation(TabControlShortcutHintAnimation.visibility) {
                self.isShortcutHintVisible = true
            }
        }

        pendingModifier = modifier
        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + TabControlShortcutHintPolicy.intentionalHoldDelay, execute: workItem)
    }

    private func cancelPendingHintShow(resetVisible: Bool) {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        pendingModifier = nil
        if resetVisible {
            withAnimation(TabControlShortcutHintAnimation.visibility) {
                isShortcutHintVisible = false
            }
        }
    }

    private func removeHostWindowObservers() {
        if let hostWindowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(hostWindowDidBecomeKeyObserver)
            self.hostWindowDidBecomeKeyObserver = nil
        }
        if let hostWindowDidResignKeyObserver {
            NotificationCenter.default.removeObserver(hostWindowDidResignKeyObserver)
            self.hostWindowDidResignKeyObserver = nil
        }
    }
}


/// Drop lifecycle state to prevent dropUpdated from re-setting state after performDrop
enum TabDropLifecycle {
    case idle
    case hovering
}

// MARK: - SurfaceTab Drop Delegate

struct TabDropDelegate: DropDelegate {
    let targetIndex: Int
    let pane: PaneState
    let layoutController: WorkspaceLayoutController
    let controller: SplitViewController
    @Binding var dropTargetIndex: Int?
    @Binding var dropLifecycle: TabDropLifecycle

    func performDrop(info: DropInfo) -> Bool {
        #if DEBUG
        NSLog("[CMUXLayout Drag] performDrop called, targetIndex: \(targetIndex)")
        #endif
#if DEBUG
        dlog("tab.drop pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex)")
#endif

        // Ensure all drag/drop side-effects run on the main actor. SwiftUI can call these
        // callbacks off-main, and SplitViewController is @MainActor.
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                performDrop(info: info)
            }
        }

        // Read from non-observable drag state — @Observable writes from createItemProvider
        // may not have propagated yet when performDrop runs.
        guard let draggedTab = controller.activeDragTab ?? controller.draggingTab,
              let sourcePaneId = controller.activeDragSourcePaneId ?? controller.dragSourcePaneId else {
            if let transfer = decodeTransfer(from: info),
               transfer.isFromCurrentProcess {
                let request = WorkspaceLayoutController.ExternalTabDropRequest(
                    tabId: SurfaceID(id: transfer.tab.id),
                    sourcePaneId: PaneID(id: transfer.sourcePaneId),
                    destination: .insert(targetPane: pane.id, targetIndex: targetIndex)
                )
                let handled = layoutController.onExternalTabDrop?(request) ?? false
                if handled {
                    clearDropState()
                }
                return handled
            }

            return performFileDrop(info: info)
        }

        // Execute synchronously when possible so the dragged tab disappears immediately.
        let applyMove = {
            // Ensure the move itself doesn't animate.
            withTransaction(Transaction(animation: nil)) {
                if sourcePaneId == pane.id {
                    guard let sourceIndex = pane.tabs.firstIndex(where: { $0.id == draggedTab.id }) else { return }
                    // Same-pane no-op: don't mutate the model (and don't show an indicator).
                    if targetIndex == sourceIndex || targetIndex == sourceIndex + 1 {
                        return
                    }
                    pane.moveTab(from: sourceIndex, to: targetIndex)
                } else {
                    _ = layoutController.moveTab(
                        SurfaceID(id: draggedTab.id),
                        toPane: pane.id,
                        atIndex: targetIndex
                    )
                }
            }
        }

        applyMove()

        // Clear visual state immediately to prevent lingering indicators.
        // Must happen synchronously before returning, not in async callback.
        // Setting dropLifecycle to idle prevents dropUpdated from re-setting dropTargetIndex.
        clearDropState()
        controller.draggingTab = nil
        controller.dragSourcePaneId = nil
        controller.activeDragTab = nil
        controller.activeDragSourcePaneId = nil

        return true
    }

    func dropEntered(info: DropInfo) {
        #if DEBUG
        NSLog("[CMUXLayout Drag] dropEntered at index: \(targetIndex)")
        dlog(
            "tab.dropEntered pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex) " +
            "hasDrag=\(controller.draggingTab != nil ? 1 : 0) " +
            "hasActive=\(controller.activeDragTab != nil ? 1 : 0)"
        )
        #endif
        dropLifecycle = .hovering
        if shouldSuppressIndicatorForNoopSamePaneDrop() {
            dropTargetIndex = nil
        } else {
            dropTargetIndex = targetIndex
        }
    }

    func dropExited(info: DropInfo) {
        #if DEBUG
        NSLog("[CMUXLayout Drag] dropExited from index: \(targetIndex)")
        dlog("tab.dropExited pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex)")
        #endif
        dropLifecycle = .idle
        if dropTargetIndex == targetIndex {
            dropTargetIndex = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Guard against dropUpdated firing after performDrop/dropExited
        // This is the key fix for the lingering indicator bug
        guard dropLifecycle == .hovering else {
#if DEBUG
            dlog("tab.dropUpdated.skip pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex) reason=lifecycle_idle")
#endif
            return DropProposal(operation: dropOperation(for: info))
        }
        // Only update if this is the active target, and suppress same-pane no-op indicators.
        if shouldSuppressIndicatorForNoopSamePaneDrop() {
            if dropTargetIndex == targetIndex {
                dropTargetIndex = nil
            }
        } else if dropTargetIndex != targetIndex {
            dropTargetIndex = targetIndex
        }
#if DEBUG
        dlog(
            "tab.dropUpdated pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex) " +
            "dropTarget=\(dropTargetIndex.map(String.init) ?? "nil")"
        )
#endif
        return DropProposal(operation: dropOperation(for: info))
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Reject drops on inactive workspaces whose views are kept alive in a ZStack.
        guard controller.isInteractive else {
#if DEBUG
            dlog("tab.validateDrop pane=\(pane.id.id.uuidString.prefix(5)) allowed=0 reason=inactive")
#endif
            return false
        }
        let hasTabTransfer = info.hasItemsConforming(to: [.tabTransfer])
        let hasFileURL = info.hasItemsConforming(to: [.fileURL])
        guard hasTabTransfer || hasFileURL else { return false }

        if hasFileURL, !hasTabTransfer {
            return canHandleFileDrop(info: info)
        }

        // Local drags use in-memory state and are always same-process.
        if controller.activeDragTab != nil || controller.draggingTab != nil {
            return true
        }

        // External drags (another CMUXLayout controller) must include a payload from this process.
        guard let transfer = decodeTransfer(from: info),
              transfer.isFromCurrentProcess else {
            return false
        }
#if DEBUG
        let hasDrag = controller.draggingTab != nil
        let hasActive = controller.activeDragTab != nil
        dlog(
            "tab.validateDrop pane=\(pane.id.id.uuidString.prefix(5)) " +
            "allowed=\(hasTabTransfer ? 1 : 0) hasDrag=\(hasDrag ? 1 : 0) hasActive=\(hasActive ? 1 : 0)"
        )
#endif
        return true
    }

    private func clearDropState() {
        dropLifecycle = .idle
        dropTargetIndex = nil
    }

    private func dropOperation(for info: DropInfo) -> DropOperation {
        info.hasItemsConforming(to: [.fileURL]) && !info.hasItemsConforming(to: [.tabTransfer]) ? .copy : .move
    }

    private func canHandleFileDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.fileURL]) else { return false }
        guard layoutController.onExternalFileDrop != nil || controller.onFileDrop != nil else { return false }
        return UnifiedPaneDropDelegate.hasReadableFileURLs()
    }

    private func performFileDrop(info: DropInfo) -> Bool {
        guard canHandleFileDrop(info: info) else { return false }
        let urls = UnifiedPaneDropDelegate.fileURLs(from: NSPasteboard(name: .drag))
        guard !urls.isEmpty else { return false }

        let destination: WorkspaceLayoutController.ExternalTabDropRequest.Destination = .insert(
            targetPane: pane.id,
            targetIndex: targetIndex
        )
        let handled = layoutController.onExternalFileDrop?(
            WorkspaceLayoutController.ExternalFileDropRequest(urls: urls, destination: destination)
        ) ?? controller.onFileDrop?(urls, pane.id) ?? false
        if handled {
            clearDropState()
        }
        return handled
    }

    private func shouldSuppressIndicatorForNoopSamePaneDrop() -> Bool {
        guard let draggedTab = controller.draggingTab,
              controller.dragSourcePaneId == pane.id,
              let sourceIndex = pane.tabs.firstIndex(where: { $0.id == draggedTab.id }) else {
            return false
        }
        // Insertion indices are expressed in "original array" coordinates; after removal,
        // inserting at `sourceIndex` or `sourceIndex + 1` results in no change.
        return targetIndex == sourceIndex || targetIndex == sourceIndex + 1
    }

    private func decodeTransfer(from string: String) -> TabTransferData? {
        guard let data = string.data(using: .utf8),
              let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) else {
            return nil
        }
        return transfer
    }

    private func decodeTransfer(from info: DropInfo) -> TabTransferData? {
        let pasteboard = NSPasteboard(name: .drag)
        let type = NSPasteboard.PasteboardType(UTType.tabTransfer.identifier)
        if let data = pasteboard.data(forType: type),
           let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) {
            return transfer
        }
        if let raw = pasteboard.string(forType: type) {
            return decodeTransfer(from: raw)
        }
        return nil
    }
}
