import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Titlebar, window chrome, native titlebar backdrop
extension ContentView {
    var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var effectiveTitlebarPadding: CGFloat {
        Self.effectiveTitlebarPadding(
            isMinimalMode: isMinimalMode,
            isFullScreen: isFullScreen,
            titlebarPadding: titlebarPadding,
            hostingSafeAreaTop: hostingSafeAreaTop
        )
    }

    static func effectiveTitlebarPadding(
        isMinimalMode: Bool,
        isFullScreen: Bool,
        titlebarPadding: CGFloat,
        hostingSafeAreaTop: CGFloat
    ) -> CGFloat {
        guard isMinimalMode else { return WindowChromeMetrics.appTitlebarHeight }
        guard !isFullScreen else { return 0 }
        return -max(0, min(titlebarPadding, hostingSafeAreaTop))
    }

    nonisolated static func customTitlebarLeadingPadding(
        isFullScreen: Bool,
        isSidebarVisible: Bool,
        sidebarWidth: CGFloat,
        minimumSidebarWidth: CGFloat,
        titlebarLeadingInset: CGFloat
    ) -> CGFloat {
        if isFullScreen && !isSidebarVisible {
            return 8
        }

        let minimumSidebarTitleInset = max(titlebarLeadingInset, minimumSidebarWidth + 12)
        guard isSidebarVisible else {
            return minimumSidebarTitleInset
        }

        let visibleSidebarTitleInset = sidebarWidth + 12
        // Absorb floating-point drift around the minimum-width clamp.
        guard sidebarWidth > minimumSidebarWidth + 0.5 else {
            return minimumSidebarTitleInset
        }
        return max(titlebarLeadingInset, visibleSidebarTitleInset)
    }

    var windowIdentifier: String { "cmux.main.\(windowId.uuidString)" }
    var windowAppearanceSnapshot: WindowAppearanceSnapshot {
        _ = titlebarThemeGeneration
        return WindowAppearanceSnapshot.current(
            unifySurfaceBackdrops: sidebarMatchTerminalBackground,
            colorScheme: AppearanceSettings.colorScheme(for: appearanceMode, fallback: colorScheme),
            sidebarMaterial: sidebarMaterial,
            sidebarBlendMode: sidebarBlendMode,
            sidebarState: sidebarStateSetting,
            sidebarTintHex: sidebarTintHex,
            sidebarTintHexLight: sidebarTintHexLight,
            sidebarTintHexDark: sidebarTintHexDark,
            sidebarTintOpacity: sidebarTintOpacity,
            sidebarCornerRadius: sidebarCornerRadius,
            sidebarBlurOpacity: sidebarBlurOpacity,
            bgGlassEnabled: bgGlassEnabled,
            bgGlassTintHex: bgGlassTintHex,
            bgGlassTintOpacity: bgGlassTintOpacity
        )
    }

    private func fakeTitlebarTextColor(appearance: WindowAppearanceSnapshot) -> Color {
        let ghosttyBackground = appearance.terminalBackgroundColor
        return ghosttyBackground.isLightColor
            ? Color.black.opacity(0.78)
            : Color.white.opacity(0.82)
    }
    private var fullscreenControls: some View {
        TitlebarControlsView(
            notificationStore: TerminalNotificationStore.shared,
            viewModel: fullscreenControlsViewModel,
            onToggleSidebar: { sidebarState.toggle() },
            onToggleNotifications: { [fullscreenControlsViewModel] in
                AppDelegate.shared?.toggleNotificationsPopover(
                    animated: true,
                    anchorView: fullscreenControlsViewModel.notificationsAnchorView
                )
            },
            onNewTab: {
                AppDelegate.shared?.performNewWorkspaceAction(
                    tabManager: tabManager,
                    debugSource: "titlebar.fullscreenNewWorkspace"
                )
            },
            onFocusHistoryBack: {
                if !tabManager.navigateBack() {
                    NSSound.beep()
                }
            },
            onFocusHistoryForward: {
                if !tabManager.navigateForward() {
                    NSSound.beep()
                }
            },
            visibilityMode: .alwaysVisible
        )
        .offset(y: -TitlebarControlsVisualMetrics.verticalLift)
    }

    var titlebarDebugChromeSnapshot: MinimalModeTitlebarDebugSnapshot {
        MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                titlebarLeftControlsLeadingInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            ),
            leftControlsTopInset: MinimalModeTitlebarDebugSettings.clamped(
                titlebarLeftControlsTopInset,
                range: MinimalModeTitlebarDebugSettings.topInsetRange
            ),
            trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                titlebarTrafficLightTabBarInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            ),
            trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                titlebarTrafficLightTitlebarLeadingInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            )
        )
    }

    private func customTitlebar(appearance: WindowAppearanceSnapshot) -> some View {
        let titlebarContentHeight = max(1, WindowChromeMetrics.appTitlebarHeight - 2)
        let leadingPadding = Self.customTitlebarLeadingPadding(
            isFullScreen: isFullScreen,
            isSidebarVisible: sidebarState.isVisible,
            sidebarWidth: sidebarWidth,
            minimumSidebarWidth: minimumSidebarWidth,
            titlebarLeadingInset: titlebarLeadingInset
        )
        return ZStack {
            // Enable window dragging from the titlebar strip without making the entire content
            // view draggable (which breaks drag gestures like tab reordering).
            WindowDragHandleView()

            TitlebarLeadingInsetReader(inset: $titlebarLeadingInset)
                .allowsHitTesting(false)

            HStack(spacing: 8) {
                if isFullScreen && !sidebarState.isVisible {
                    fullscreenControls
                }

                // Draggable folder icon + focused command name
                if let directory = focusedDirectory {
                    DetachedFolderDragIcon(directory: directory)
                        .frame(width: 16, height: 16)
                        .padding(.leading, -6)
                }

                Text(titlebarText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(fakeTitlebarTextColor(appearance: appearance))
                    .lineLimit(1)
                    .allowsHitTesting(false)

                Spacer()

            }
            .frame(height: titlebarContentHeight)
            .padding(.top, 2)
            .padding(.leading, leadingPadding)
            .padding(.trailing, 8)
        }
        .frame(height: WindowChromeMetrics.appTitlebarHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(TitlebarDoubleClickMonitorView())
        .overlay(alignment: .bottom) {
            WindowChromeBorder(orientation: .horizontal)
                .padding(.leading, sidebarState.isVisible ? sidebarWidth : 0)
        }
    }

    func workspaceTitlebarBand(appearance: WindowAppearanceSnapshot) -> some View {
        Color.clear
            .frame(height: WindowChromeMetrics.appTitlebarHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                customTitlebar(appearance: appearance)
                    // The workspace titlebar band spans the full window width and sits at
                    // zIndex(100) over the content/sidebar layout. Its drag/double-click
                    // surface (`WindowDragHandleView` + `.contentShape(Rectangle())`) must
                    // not cover the right sidebar, whose mode bar (Files/Search/Feed/Vault)
                    // lives inside the titlebar-height strip — otherwise the band wins the
                    // hit-test and swallows every click/hover on those buttons (#5099).
                    // Confine the interactive titlebar surface to the area left of the
                    // right sidebar, matching the pre-#5017 "only over terminal content,
                    // not the sidebar" intent. The left sidebar's titlebar controls live in
                    // the AppKit titlebar accessory (above this band), so only the trailing
                    // (right-sidebar) edge needs to be ceded here.
                    //
                    // `rightSidebarWidth` is already `rightSidebarVisible ? fileExplorerWidth : 0`,
                    // so it collapses to 0 when the sidebar is hidden. The sidebar panel itself
                    // snaps without animation (`.transaction { $0.animation = nil }`), so we match
                    // that here — otherwise this inset could animate out of step with the panel on
                    // toggle and momentarily expose (or re-cover) the mode bar mid-transition.
                    .padding(.trailing, rightSidebarWidth)
                    .animation(nil, value: rightSidebarWidth)
            }
            .overlay(alignment: .topLeading) {
                if isFullScreen && sidebarState.isVisible {
                    fullscreenControls
                        .environment(\.colorScheme, appearance.sidebarContentColorScheme)
                        .padding(.leading, 10)
                        .padding(.top, 4)
                }
            }
    }

    func syncTrafficLightInset() {
        let inset: CGFloat = (isMinimalMode && !sidebarState.isVisible && !isFullScreen)
            ? CGFloat(titlebarDebugChromeSnapshot.trafficLightTabBarLeadingInset)
            : 0
        tabManager.syncWorkspaceTabBarLeadingInset(inset)
    }

    func applyTitlebarDebugChromeChange() {
        if let observedWindow {
            AppDelegate.shared?.applyWindowDecorations(to: observedWindow)
        }
        syncTrafficLightInset()
    }

    func schedulePortalGeometrySynchronize() {
        if let observedWindow {
            TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
            BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
        } else {
            TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
            BrowserWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
        }
    }

    func refreshWindowChromeMetrics(for window: NSWindow) {
        // Keep native measurements around for minimal WindowGroup safe-area cancellation.
        // Standard mode uses cmux's visual chrome height for layout.
        let computedTitlebarHeight = window.frame.height - window.contentLayoutRect.height
        let nextPadding = WindowChromeMetrics.clampedTitlebarHeight(computedTitlebarHeight)
        let nextSafeAreaTop = max(0, window.contentView?.safeAreaInsets.top ?? 0)
        if abs(titlebarPadding - nextPadding) > 0.5 {
            DispatchQueue.main.async {
                titlebarPadding = nextPadding
            }
        }
        if abs(hostingSafeAreaTop - nextSafeAreaTop) > 0.5 {
            DispatchQueue.main.async {
                hostingSafeAreaTop = nextSafeAreaTop
            }
        }
    }

    func updateTitlebarText() {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            if !titlebarText.isEmpty {
                titlebarText = ""
            }
            return
        }
        let title = tabManager.resolvedWorkspaceDisplayTitle(for: tab)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if titlebarText != title {
            titlebarText = title
        }
    }

    func scheduleTitlebarTextRefresh() {
        titlebarTextUpdateCoalescer.signal {
            updateTitlebarText()
        }
    }

    func scheduleTitlebarThemeRefresh(
        reason: String,
        backgroundEventId: UInt64? = nil,
        backgroundSource: String? = nil,
        notificationPayloadHex: String? = nil
    ) {
        let previousGeneration = titlebarThemeGeneration
        titlebarThemeGeneration &+= 1
        if GhosttyApp.shared.backgroundLogEnabled {
            let eventLabel = backgroundEventId.map(String.init) ?? "nil"
            let sourceLabel = backgroundSource ?? "nil"
            let payloadLabel = notificationPayloadHex ?? "nil"
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh scheduled reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel) previousGeneration=\(previousGeneration) generation=\(titlebarThemeGeneration) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
        }
    }

    func scheduleTitlebarThemeRefreshFromWorkspace(
        workspaceId: UUID,
        reason: String,
        backgroundEventId: UInt64?,
        backgroundSource: String?,
        notificationPayloadHex: String?
    ) {
        guard tabManager.selectedTabId == workspaceId else {
            guard GhosttyApp.shared.backgroundLogEnabled else { return }
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh skipped workspace=\(workspaceId.uuidString) selected=\(tabManager.selectedTabId?.uuidString ?? "nil") reason=\(reason)"
            )
            return
        }

        scheduleTitlebarThemeRefresh(
            reason: reason,
            backgroundEventId: backgroundEventId,
            backgroundSource: backgroundSource,
            notificationPayloadHex: notificationPayloadHex
        )
    }

    func updateWindowGlassTint() {
        // Find this view's main window by identifier (keyWindow might be a debug panel/settings).
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == windowIdentifier }) else { return }
        let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
        WindowBackdropController.updateGlassTint(to: window, color: tintColor)
    }

    func removeNativeTitlebarBackdrop(in window: NSWindow) {
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview else { return }

        let identifier = NSUserInterfaceItemIdentifier("cmux.nativeTitlebarBackdrop")
        let existing = themeFrame.subviews.first { $0.identifier == identifier } as? NativeTitlebarBackdropView
        existing?.removeFromSuperview()
    }

    func syncNativeTitlebarBackdrop(
        in window: NSWindow,
        enabled: Bool,
        usesGlassStyle: Bool
    ) {
        guard let titlebarContainer = nativeTitlebarContainer(in: window) else { return }
        let titlebarView = firstNativeDescendant(
            in: titlebarContainer,
            className: "NSTitlebarView",
            includeRoot: true
        )
        let titlebarBackgroundViews = nativeDescendants(
            in: titlebarContainer,
            className: "NSTitlebarBackgroundView"
        )
        let effectViews = nativeDescendants(in: titlebarContainer, className: "NSVisualEffectView")

        if enabled {
            rememberNativeTitlebarBackdropState(
                titlebarContainer: titlebarContainer,
                titlebarView: titlebarView,
                titlebarBackgroundViews: titlebarBackgroundViews,
                effectViews: effectViews
            )
        } else {
            restoreNativeTitlebarBackdropState(
                titlebarContainer: titlebarContainer,
                titlebarView: titlebarView,
                titlebarBackgroundViews: titlebarBackgroundViews,
                effectViews: effectViews
            )
            return
        }

        titlebarContainer.wantsLayer = true
        titlebarContainer.layer?.backgroundColor = usesGlassStyle ? NSColor.clear.cgColor : nil
        titlebarContainer.layer?.isOpaque = false
        titlebarView?.wantsLayer = true
        titlebarView?.layer?.backgroundColor = usesGlassStyle ? NSColor.clear.cgColor : nil
        titlebarView?.layer?.isOpaque = false
        for titlebarBackgroundView in titlebarBackgroundViews {
            titlebarBackgroundView.isHidden = true
        }
        for effectView in effectViews {
            effectView.isHidden = true
        }
        window.titlebarAppearsTransparent = true
    }

    private static var unifiedTitlebarLayerAppliedKey: UInt8 = 0
    private static var unifiedTitlebarLayerColorKey: UInt8 = 0
    private static var unifiedTitlebarLayerOpaqueKey: UInt8 = 0
    private static var unifiedTitlebarHiddenAppliedKey: UInt8 = 0
    private static var unifiedTitlebarHiddenKey: UInt8 = 0

    private func rememberNativeTitlebarBackdropState(
        titlebarContainer: NSView,
        titlebarView: NSView?,
        titlebarBackgroundViews: [NSView],
        effectViews: [NSView]
    ) {
        rememberNativeTitlebarLayerState(titlebarContainer)
        if let titlebarView {
            rememberNativeTitlebarLayerState(titlebarView)
        }
        for titlebarBackgroundView in titlebarBackgroundViews {
            rememberNativeTitlebarHiddenState(titlebarBackgroundView)
        }
        for effectView in effectViews {
            rememberNativeTitlebarHiddenState(effectView)
        }
    }

    private func restoreNativeTitlebarBackdropState(
        titlebarContainer: NSView,
        titlebarView: NSView?,
        titlebarBackgroundViews: [NSView],
        effectViews: [NSView]
    ) {
        restoreNativeTitlebarLayerState(titlebarContainer)
        if let titlebarView {
            restoreNativeTitlebarLayerState(titlebarView)
        }
        for titlebarBackgroundView in titlebarBackgroundViews {
            restoreNativeTitlebarHiddenState(titlebarBackgroundView)
        }
        for effectView in effectViews {
            restoreNativeTitlebarHiddenState(effectView)
        }
    }

    private func rememberNativeTitlebarLayerState(_ view: NSView) {
        guard objc_getAssociatedObject(view, &Self.unifiedTitlebarLayerAppliedKey) == nil else { return }

        objc_setAssociatedObject(view, &Self.unifiedTitlebarLayerAppliedKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(view, &Self.unifiedTitlebarLayerColorKey, view.layer?.backgroundColor ?? NSNull(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(view, &Self.unifiedTitlebarLayerOpaqueKey, view.layer.map { NSNumber(value: $0.isOpaque) } ?? NSNull(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func restoreNativeTitlebarLayerState(_ view: NSView) {
        guard objc_getAssociatedObject(view, &Self.unifiedTitlebarLayerAppliedKey) != nil else { return }

        if let storedColor = objc_getAssociatedObject(view, &Self.unifiedTitlebarLayerColorKey),
           !(storedColor is NSNull) {
            view.layer?.backgroundColor = storedColor as! CGColor
        } else {
            view.layer?.backgroundColor = nil
        }

        if let isOpaque = objc_getAssociatedObject(view, &Self.unifiedTitlebarLayerOpaqueKey) as? NSNumber {
            view.layer?.isOpaque = isOpaque.boolValue
        }

        objc_setAssociatedObject(view, &Self.unifiedTitlebarLayerAppliedKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(view, &Self.unifiedTitlebarLayerColorKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(view, &Self.unifiedTitlebarLayerOpaqueKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func rememberNativeTitlebarHiddenState(_ view: NSView) {
        guard objc_getAssociatedObject(view, &Self.unifiedTitlebarHiddenAppliedKey) == nil else { return }

        objc_setAssociatedObject(view, &Self.unifiedTitlebarHiddenAppliedKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(view, &Self.unifiedTitlebarHiddenKey, NSNumber(value: view.isHidden), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func restoreNativeTitlebarHiddenState(_ view: NSView) {
        guard objc_getAssociatedObject(view, &Self.unifiedTitlebarHiddenAppliedKey) != nil else { return }

        if let hidden = objc_getAssociatedObject(view, &Self.unifiedTitlebarHiddenKey) as? NSNumber {
            view.isHidden = hidden.boolValue
        }

        objc_setAssociatedObject(view, &Self.unifiedTitlebarHiddenAppliedKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(view, &Self.unifiedTitlebarHiddenKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func nativeTitlebarContainer(in window: NSWindow) -> NSView? {
        if !window.styleMask.contains(.fullScreen) {
            return window.contentView.flatMap {
                firstNativeDescendant(
                    in: nativeRootView(from: $0),
                    className: "NSTitlebarContainerView",
                    includeRoot: true
                )
            }
        }

        for candidate in NSApp.windows where candidate.className == "NSToolbarFullScreenWindow" {
            guard candidate.parent == window else { continue }
            if let contentView = candidate.contentView {
                return firstNativeDescendant(
                    in: nativeRootView(from: contentView),
                    className: "NSTitlebarContainerView",
                    includeRoot: true
                )
            }
        }

        return nil
    }

    private func nativeRootView(from view: NSView) -> NSView {
        var root = view
        while let superview = root.superview {
            root = superview
        }
        return root
    }

    private func firstNativeDescendant(
        in view: NSView,
        className: String,
        includeRoot: Bool = false
    ) -> NSView? {
        if includeRoot, String(describing: type(of: view)) == className {
            return view
        }

        for subview in view.subviews {
            if String(describing: type(of: subview)) == className {
                return subview
            }
            if let found = firstNativeDescendant(in: subview, className: className) {
                return found
            }
        }

        return nil
    }

    private func nativeDescendants(in view: NSView, className: String) -> [NSView] {
        var result: [NSView] = []
        for subview in view.subviews {
            if String(describing: type(of: subview)) == className {
                result.append(subview)
            }
            result.append(contentsOf: nativeDescendants(in: subview, className: className))
        }
        return result
    }

    func setTitlebarControlsHidden(_ hidden: Bool, in window: NSWindow) {
        let controlsId = NSUserInterfaceItemIdentifier("cmux.titlebarControls")
        let shouldHide = hidden || isMinimalMode
        for accessory in window.titlebarAccessoryViewControllers {
            if accessory.view.identifier == controlsId {
                accessory.isHidden = shouldHide
                accessory.view.alphaValue = shouldHide ? 0 : 1
            }
        }
    }

}
