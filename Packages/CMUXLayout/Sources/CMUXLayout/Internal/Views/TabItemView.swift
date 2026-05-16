import SwiftUI
import AppKit

enum TabControlShortcutHintAnimation {
    static let visibility: Animation = .easeOut(duration: 0.12)
}

extension View {
    func tabControlShortcutHintVisibilityAnimation<Value: Equatable>(value: Value) -> some View {
        animation(TabControlShortcutHintAnimation.visibility, value: value)
    }
}

private enum TabControlShortcutHintDebugSettings {
    static let xKey = "shortcutHintPaneTabXOffset"
    static let yKey = "shortcutHintPaneTabYOffset"
    static let alwaysShowKey = "shortcutHintAlwaysShow"
    static let defaultX = 0.0
    static let defaultY = 0.0
    static let defaultAlwaysShow = false
    static let range: ClosedRange<Double> = -20...20

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

enum SurfaceItemStyling {
    static func iconSaturation(hasRasterIcon: Bool, tabSaturation: Double) -> Double {
        hasRasterIcon ? 1.0 : tabSaturation
    }

    static func shouldShowHoverBackground(isHovered: Bool, isSelected: Bool) -> Bool {
        isHovered && !isSelected
    }

    static func resolvedFaviconImage(existing: NSImage?, incomingData: Data?) -> NSImage? {
        guard let incomingData else { return nil }
        if let decoded = NSImage(data: incomingData) {
            // Favicon bitmaps must never be treated as template/tintable symbols.
            decoded.isTemplate = false
            return decoded
        }
        return existing
    }
}

/// Individual tab view with icon, title, close button, and dirty indicator
struct SurfaceItemView: View {
    let tab: SurfaceItem
    let isSelected: Bool
    let showsZoomIndicator: Bool
    let appearance: WorkspaceLayoutConfiguration.Appearance
    let saturation: Double
    let trailingSeparatorBottomInset: CGFloat
    let controlShortcutDigit: Int?
    let allowsShortcutHints: Bool
    let showsControlShortcutHint: Bool
    let shortcutModifierSymbol: String
    let contextMenuState: TabContextMenuState
    let onSelect: () -> Void
    let onClose: () -> Void
    let onZoomToggle: () -> Void
    let onContextAction: (SurfaceContextAction) -> Void
    let onMoveDestination: (String) -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false
    @State private var isZoomHovered = false
    @State private var showGlobeFallback = true
    @State private var globeFallbackWorkItem: DispatchWorkItem?
    @State private var lastIsLoadingObserved = false
    @State private var lastLoadingStoppedAt: Date?
    @State private var renderedFaviconData: Data?
    @State private var renderedFaviconImage: NSImage?
    @AppStorage(TabControlShortcutHintDebugSettings.xKey) private var controlShortcutHintXOffset = TabControlShortcutHintDebugSettings.defaultX
    @AppStorage(TabControlShortcutHintDebugSettings.yKey) private var controlShortcutHintYOffset = TabControlShortcutHintDebugSettings.defaultY
    @AppStorage(TabControlShortcutHintDebugSettings.alwaysShowKey) private var alwaysShowShortcutHints = TabControlShortcutHintDebugSettings.defaultAlwaysShow

    var body: some View {
        HStack(spacing: 0) {
            // Icon + title block uses the standard spacing, but keep the close affordance tight.
            HStack(spacing: TabBarMetrics.contentSpacing) {
                let iconSlotSize = TabBarMetrics.iconSize
                let iconTint = isSelected
                    ? TabBarColors.activeText(for: appearance)
                    : TabBarColors.inactiveText(for: appearance)
                let faviconImage = renderedFaviconImage ?? tab.iconImageData.flatMap { NSImage(data: $0) }

                Group {
                    if tab.isLoading {
                        // Slightly smaller than the icon slot so it reads cleaner at tab scale.
                        TabLoadingSpinner(size: iconSlotSize * 0.86, color: iconTint)
                    } else if let image = faviconImage {
                        FaviconIconView(image: image)
                            .frame(width: iconSlotSize, height: iconSlotSize, alignment: .center)
                            .clipped()
                    } else if let iconName = tab.icon {
                        if iconName == "globe", !showGlobeFallback {
                            // Avoid a distracting "globe -> favicon" flash: show a neutral placeholder
                            // briefly while the favicon fetch finishes. If no favicon arrives, we
                            // reveal the globe after a short delay.
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(iconTint.opacity(0.25), lineWidth: 1)
                        } else {
                            Image(systemName: iconName)
                                .font(.system(size: glyphSize(for: iconName)))
                                .foregroundStyle(iconTint)
                        }
                    }
                }
                // Keep downloaded favicon bitmaps in full color even for inactive tab bars.
                .saturation(SurfaceItemStyling.iconSaturation(hasRasterIcon: faviconImage != nil, tabSaturation: saturation))
                .transaction { tx in
                    // Prevent incidental parent animations from briefly fading icon content.
                    tx.animation = nil
                }
                .frame(width: iconSlotSize, height: iconSlotSize, alignment: .center)
                .onAppear {
                    updateRenderedFaviconImage()
                    updateGlobeFallback()
                }
                .onDisappear {
                    globeFallbackWorkItem?.cancel()
                    globeFallbackWorkItem = nil
                }
                .onChange(of: tab.isLoading) { _ in updateGlobeFallback() }
                .onChange(of: tab.iconImageData) { _ in
                    updateRenderedFaviconImage()
                    updateGlobeFallback()
                }
                .onChange(of: tab.icon) { _ in updateGlobeFallback() }

                Text(tab.title)
                    .font(.system(size: appearance.tabTitleFontSize))
                    .lineLimit(1)
                    .foregroundStyle(
                        isSelected
                            ? TabBarColors.activeText(for: appearance)
                            : TabBarColors.inactiveText(for: appearance)
                    )
                    .saturation(saturation)

                if showsZoomIndicator {
                    Button {
                        onZoomToggle()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: accessoryFontSize, weight: .semibold))
                            .foregroundStyle(
                                isZoomHovered
                                    ? TabBarColors.activeText(for: appearance)
                                    : TabBarColors.inactiveText(for: appearance)
                            )
                            .frame(width: accessorySlotSize, height: accessorySlotSize)
                            .background(
                                Circle()
                                    .fill(
                                        isZoomHovered
                                            ? TabBarColors.hoveredTabBackground(for: appearance)
                                            : .clear
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isZoomHovered = hovering
                    }
                    .saturation(saturation)
                    .accessibilityLabel("Exit zoom")
                }
            }

            Spacer(minLength: 0)

            // Close button / dirty indicator / shortcut hint share the same trailing slot.
            trailingAccessory
        }
        .padding(.horizontal, TabBarMetrics.tabHorizontalPadding)
        .frame(
            minWidth: TabBarMetrics.tabMinWidth,
            maxWidth: TabBarMetrics.tabMaxWidth,
            minHeight: tabHeight,
            maxHeight: tabHeight
        )
        .background(tabBackground.saturation(saturation))
        .tabControlShortcutHintVisibilityAnimation(value: showsShortcutHint)
        .contentShape(Rectangle())
        // Middle click to close (macOS convention).
        // Uses an AppKit event monitor so it doesn't interfere with left click selection or drag/reorder.
        .background(MiddleClickMonitorView(onMiddleClick: {
            guard !tab.isPinned else { return }
            onClose()
        }))
        .background(TabContextMenuPresenter(
            snapshot: TabContextMenuSnapshot(tabId: tab.id, state: contextMenuState),
            onContextAction: onContextAction,
            onMoveDestination: onMoveDestination
        ))
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            // Keep icon rendering stable while hovering; only accessory/background elements animate.
            isHovered = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .safeHelp(tab.title)
    }

    private func glyphSize(for iconName: String) -> CGFloat {
        // `terminal.fill` reads visually heavier than most symbols at the same point size.
        // Hardcode sizes to avoid cross-glyph layout shifts.
        if iconName == "terminal.fill" || iconName == "terminal" || iconName == "globe" {
            return max(10, TabBarMetrics.iconSize - 2.5)
        }
        return TabBarMetrics.iconSize
    }

    private var shortcutHintLabel: String? {
        guard let controlShortcutDigit else { return nil }
        return "\(shortcutModifierSymbol)\(controlShortcutDigit)"
    }

    private var showsShortcutHint: Bool {
        allowsShortcutHints && (showsControlShortcutHint || alwaysShowShortcutHints) && shortcutHintLabel != nil
    }

    private var shortcutHintSlotWidth: CGFloat {
        guard let label = shortcutHintLabel else {
            return accessorySlotSize
        }
        let positiveDebugInset = max(0, CGFloat(TabControlShortcutHintDebugSettings.clamped(controlShortcutHintXOffset))) + 2
        return max(accessorySlotSize, shortcutHintWidth(for: label) + positiveDebugInset)
    }

    private var accessoryFontSize: CGFloat {
        max(8, appearance.tabTitleFontSize - 2)
    }

    private var accessorySlotSize: CGFloat {
        // Keep accessory affordances readable when the tab title font is increased.
        min(tabHeight, max(TabBarMetrics.closeButtonSize, ceil(accessoryFontSize + 4)))
    }

    private var tabHeight: CGFloat {
        max(1, appearance.tabBarHeight)
    }

    private func shortcutHintWidth(for label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: accessoryFontSize, weight: .semibold)
        let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth) + 8
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        ZStack(alignment: .center) {
            if let shortcutHintLabel {
                Text(shortcutHintLabel)
                    .font(.system(size: accessoryFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(
                        isSelected
                            ? TabBarColors.activeText(for: appearance)
                            : TabBarColors.inactiveText(for: appearance)
                    )
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.regularMaterial)
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.white.opacity(0.30), lineWidth: 0.8)
                            )
                            .shadow(color: Color.black.opacity(0.22), radius: 2, x: 0, y: 1)
                    )
                    .offset(
                        x: TabControlShortcutHintDebugSettings.clamped(controlShortcutHintXOffset),
                        y: TabControlShortcutHintDebugSettings.clamped(controlShortcutHintYOffset)
                    )
                    .opacity(showsShortcutHint ? 1 : 0)
                    .allowsHitTesting(false)
            }

            closeOrDirtyIndicator
                .opacity(showsShortcutHint ? 0 : 1)
                .allowsHitTesting(!showsShortcutHint)
        }
        .frame(width: shortcutHintSlotWidth, height: accessorySlotSize, alignment: .center)
        .tabControlShortcutHintVisibilityAnimation(value: showsShortcutHint)
    }

    private func updateGlobeFallback() {
        // Track load transitions so we can avoid an "empty placeholder -> globe" flash on brand-new tabs.
        if lastIsLoadingObserved && !tab.isLoading {
            lastLoadingStoppedAt = Date()
        }
        lastIsLoadingObserved = tab.isLoading

        globeFallbackWorkItem?.cancel()
        globeFallbackWorkItem = nil

        // Only delay the globe fallback right after a navigation completes, when a favicon is likely to
        // arrive soon. Otherwise (e.g. a brand-new tab), show the globe immediately.
        let recentlyStoppedLoading: Bool = {
            guard let t = lastLoadingStoppedAt else { return false }
            return Date().timeIntervalSince(t) < 1.5
        }()
        let shouldDelayGlobe = (tab.icon == "globe") && (tab.iconImageData == nil) && !tab.isLoading && recentlyStoppedLoading
        if !shouldDelayGlobe {
            showGlobeFallback = true
            return
        }

        showGlobeFallback = false
        let work = DispatchWorkItem {
            showGlobeFallback = true
        }
        globeFallbackWorkItem = work
        // Give favicon fetches a little longer before showing the globe fallback to reduce brief flashes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.90, execute: work)
    }

    private func updateRenderedFaviconImage() {
        guard renderedFaviconData != tab.iconImageData ||
                (renderedFaviconImage == nil && tab.iconImageData != nil) else { return }
        renderedFaviconData = tab.iconImageData
        renderedFaviconImage = SurfaceItemStyling.resolvedFaviconImage(
            existing: renderedFaviconImage,
            incomingData: tab.iconImageData
        )
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if tab.isLoading { parts.append("Loading") }
        if tab.isPinned { parts.append("Pinned") }
        if tab.showsNotificationBadge { parts.append("Unread") }
        if tab.isDirty { parts.append("Modified") }
        if showsZoomIndicator { parts.append("Zoomed") }
        return parts.joined(separator: ", ")
    }

    // MARK: - SurfaceTab Background

    @ViewBuilder
    private var tabBackground: some View {
        ZStack(alignment: .top) {
            // Background fill (hover)
            if SurfaceItemStyling.shouldShowHoverBackground(isHovered: isHovered, isSelected: isSelected) {
                Rectangle()
                    .fill(TabBarColors.hoveredTabBackground(for: appearance))
            } else {
                Color.clear
            }

            // Right border separator
            HStack {
                Spacer()
                Rectangle()
                    .fill(TabBarColors.separator(for: appearance))
                    .frame(width: 1)
                    .padding(.bottom, max(0, trailingSeparatorBottomInset))
            }
        }
    }

    // MARK: - Close Button / Dirty Indicator

    @ViewBuilder
    private var closeOrDirtyIndicator: some View {
        ZStack {
            // Dirty indicator (shown when dirty and not hovering, hidden for selected tab)
            if (!isSelected && !isHovered && !isCloseHovered) && (tab.isDirty || tab.showsNotificationBadge) {
                HStack(spacing: 2) {
                    if tab.showsNotificationBadge {
                        Circle()
                            .fill(TabBarColors.notificationBadge(for: appearance))
                            .frame(width: TabBarMetrics.notificationBadgeSize, height: TabBarMetrics.notificationBadgeSize)
                    }
                    if tab.isDirty {
                        Circle()
                            .fill(TabBarColors.dirtyIndicator(for: appearance))
                            .frame(width: TabBarMetrics.dirtyIndicatorSize, height: TabBarMetrics.dirtyIndicatorSize)
                            .saturation(saturation)
                    }
                }
            }

            if tab.isPinned {
                if isSelected || isHovered || isCloseHovered || (!tab.isDirty && !tab.showsNotificationBadge) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: TabBarMetrics.closeIconSize, weight: .semibold))
                        .foregroundStyle(TabBarColors.inactiveText(for: appearance))
                        .frame(width: accessorySlotSize, height: accessorySlotSize)
                        .saturation(saturation)
                }
            } else if isSelected || isHovered || isCloseHovered {
                // Close button (always visible on active tab, shown on hover for others)
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: TabBarMetrics.closeIconSize, weight: .semibold))
                        .foregroundStyle(
                            isCloseHovered
                                ? TabBarColors.activeText(for: appearance)
                                : TabBarColors.inactiveText(for: appearance)
                        )
                        .frame(width: accessorySlotSize, height: accessorySlotSize)
                        .background(
                            Circle()
                                .fill(
                                    isCloseHovered
                                        ? TabBarColors.hoveredTabBackground(for: appearance)
                                        : .clear
                                )
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isCloseHovered = hovering
                }
                .saturation(saturation)
            }
        }
        .frame(width: accessorySlotSize, height: accessorySlotSize)
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isHovered)
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isCloseHovered)
    }
}

private struct TabLoadingSpinner: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 0.9s per revolution feels a bit snappier at tab-icon scale.
            let angle = (t.truncatingRemainder(dividingBy: 0.9) / 0.9) * 360.0

            ZStack {
                Circle()
                    .stroke(color.opacity(0.20), lineWidth: ringWidth)
                Circle()
                    .trim(from: 0.0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: size, height: size)
        }
    }

    private var ringWidth: CGFloat {
        max(1.6, size * 0.14)
    }
}

private struct FaviconIconView: NSViewRepresentable {
    let image: NSImage

    final class ContainerView: NSView {
        let imageView = NSImageView(frame: .zero)

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            imageView.imageScaling = .scaleProportionallyDown
            imageView.imageAlignment = .alignCenter
            imageView.animates = false
            imageView.contentTintColor = nil
            imageView.autoresizingMask = [.width, .height]
            addSubview(imageView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var intrinsicContentSize: NSSize {
            .zero
        }

        override func layout() {
            super.layout()
            imageView.frame = bounds.integral
        }
    }

    func makeNSView(context: Context) -> ContainerView {
        ContainerView(frame: .zero)
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        image.isTemplate = false
        if nsView.imageView.image !== image {
            nsView.imageView.image = image
        }
        nsView.imageView.contentTintColor = nil
    }
}

private struct MiddleClickMonitorView: NSViewRepresentable {
    let onMiddleClick: () -> Void

    final class Coordinator {
        var onMiddleClick: (() -> Void)?
        weak var view: NSView?
        var monitor: Any?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        context.coordinator.view = view
        context.coordinator.onMiddleClick = onMiddleClick

        // Monitor only middle clicks so we don't break drag/reorder or normal selection.
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp]) { [weak coordinator] event in
            guard event.buttonNumber == 2 else { return event }
            guard let coordinator, let v = coordinator.view, let w = v.window else { return event }
            guard event.window === w else { return event }

            let p = v.convert(event.locationInWindow, from: nil)
            guard v.bounds.contains(p) else { return event }

            coordinator.onMiddleClick?()
            return nil // swallow so it doesn't also select the tab
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onMiddleClick = onMiddleClick
    }
}

struct TabContextMenuSnapshot {
    let tabId: UUID
    let state: TabContextMenuState
}

final class TabContextMenuActionTarget: NSObject {
    var onContextAction: ((SurfaceContextAction) -> Void)?
    var onMoveDestination: ((String) -> Void)?

    @objc func performContextAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let action = SurfaceContextAction(rawValue: rawValue) else {
            return
        }
        onContextAction?(action)
    }

    @objc func performMoveDestination(_ sender: NSMenuItem) {
        guard let destinationId = sender.representedObject as? String else { return }
        onMoveDestination?(destinationId)
    }
}

enum TabContextMenuBuilder {
    static func makeMenu(
        snapshot: TabContextMenuSnapshot,
        target: TabContextMenuActionTarget
    ) -> NSMenu {
        let state = snapshot.state
        let menu = NSMenu()
        menu.autoenablesItems = false

        addAction(
            title: localized("tabContext.renameTab", defaultValue: "Rename Surface…"),
            action: .rename,
            state: state,
            target: target,
            to: menu
        )

        if state.hasCustomTitle {
            addAction(
                title: localized("tabContext.removeCustomTabName", defaultValue: "Remove Custom Surface Name"),
                action: .clearName,
                state: state,
                target: target,
                to: menu
            )
        }

        menu.addItem(.separator())

        addAction(
            title: localized("tabContext.closeTabsToLeft", defaultValue: "Close Tabs to Left"),
            action: .closeToLeft,
            enabled: state.canCloseToLeft,
            state: state,
            target: target,
            to: menu
        )
        addAction(
            title: localized("tabContext.closeTabsToRight", defaultValue: "Close Tabs to Right"),
            action: .closeToRight,
            enabled: state.canCloseToRight,
            state: state,
            target: target,
            to: menu
        )
        addAction(
            title: localized("tabContext.closeOtherTabs", defaultValue: "Close Other Tabs"),
            action: .closeOthers,
            enabled: state.canCloseOthers,
            state: state,
            target: target,
            to: menu
        )

        menu.addItem(moveSubmenuItem(state: state, target: target))

        if state.isTerminal {
            addAction(
                title: localized("command.moveTabToLeftPane.title", defaultValue: "Move to Left Pane"),
                action: .moveToLeftPane,
                enabled: state.canMoveToLeftPane,
                state: state,
                target: target,
                to: menu
            )
            addAction(
                title: localized("command.moveTabToRightPane.title", defaultValue: "Move to Right Pane"),
                action: .moveToRightPane,
                enabled: state.canMoveToRightPane,
                state: state,
                target: target,
                to: menu
            )
        }

        menu.addItem(.separator())

        addAction(
            title: localized("tabContext.newTerminalTabToRight", defaultValue: "New Terminal Surface to Right"),
            action: .newTerminalToRight,
            state: state,
            target: target,
            to: menu
        )
        addAction(
            title: localized("tabContext.newBrowserTabToRight", defaultValue: "New Browser Surface to Right"),
            action: .newBrowserToRight,
            state: state,
            target: target,
            to: menu
        )

        if state.isBrowser {
            menu.addItem(.separator())
            addAction(
                title: localized("tabContext.reloadTab", defaultValue: "Reload Surface"),
                action: .reload,
                state: state,
                target: target,
                to: menu
            )
            addAction(
                title: localized("tabContext.duplicateTab", defaultValue: "Duplicate Surface"),
                action: .duplicate,
                state: state,
                target: target,
                to: menu
            )
        }

        menu.addItem(.separator())

        if state.hasSplits {
            addAction(
                title: state.isZoomed
                    ? localized("tabContext.exitZoom", defaultValue: "Exit Zoom")
                    : localized("tabContext.zoomPane", defaultValue: "Zoom Pane"),
                action: .toggleZoom,
                state: state,
                target: target,
                to: menu
            )
        }

        addAction(
            title: state.isPinned
                ? localized("tabContext.unpinTab", defaultValue: "Unpin Surface")
                : localized("tabContext.pinTab", defaultValue: "Pin Surface"),
            action: .togglePin,
            state: state,
            target: target,
            to: menu
        )

        if state.isUnread {
            addAction(
                title: localized("tabContext.markTabAsRead", defaultValue: "Mark Surface as Read"),
                action: .markAsRead,
                enabled: state.canMarkAsRead,
                state: state,
                target: target,
                to: menu
            )
        } else {
            addAction(
                title: localized("tabContext.markTabAsUnread", defaultValue: "Mark Surface as Unread"),
                action: .markAsUnread,
                enabled: state.canMarkAsUnread,
                state: state,
                target: target,
                to: menu
            )
        }

        menu.addItem(.separator())

        addAction(
            title: localized("command.copyIdentifiers.title", defaultValue: "Copy IDs"),
            action: .copyIdentifiers,
            state: state,
            target: target,
            to: menu
        )

        return menu
    }

    private static func moveSubmenuItem(
        state: TabContextMenuState,
        target: TabContextMenuActionTarget
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: localized("tabContext.moveTab", defaultValue: "Move Surface"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        addAction(
            title: localized("command.moveTabToNewWorkspace.title", defaultValue: "Move Surface to New Workspace"),
            action: .moveToNewWorkspace,
            enabled: state.canMoveToNewWorkspace,
            state: state,
            target: target,
            to: submenu
        )
        for destination in state.moveDestinations {
            let destinationItem = NSMenuItem(
                title: destination.title,
                action: #selector(TabContextMenuActionTarget.performMoveDestination(_:)),
                keyEquivalent: ""
            )
            destinationItem.target = target
            destinationItem.representedObject = destination.id
            destinationItem.isEnabled = destination.isEnabled
            submenu.addItem(destinationItem)
        }
        item.submenu = submenu
        item.isEnabled = state.canMoveToNewWorkspace || !state.moveDestinations.isEmpty
        return item
    }

    @discardableResult
    private static func addAction(
        title: String,
        action: SurfaceContextAction,
        enabled: Bool = true,
        state: TabContextMenuState,
        target: TabContextMenuActionTarget,
        to menu: NSMenu
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(TabContextMenuActionTarget.performContextAction(_:)),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = action.rawValue
        item.isEnabled = enabled
        if let shortcut = state.shortcuts[action] {
            applyShortcut(shortcut, to: item)
        }
        menu.addItem(item)
        return item
    }

    private static func applyShortcut(_ shortcut: KeyboardShortcut, to item: NSMenuItem) {
        item.keyEquivalent = String(shortcut.key.character).lowercased()
        item.keyEquivalentModifierMask = shortcut.modifiers.nsMenuModifierMask
    }

    private static func localized(_ key: String, defaultValue: String) -> String {
        Bundle.module.localizedString(forKey: key, value: defaultValue, table: nil)
    }
}

private extension EventModifiers {
    var nsMenuModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}

private struct TabContextMenuPresenter: NSViewRepresentable {
    let snapshot: TabContextMenuSnapshot
    let onContextAction: (SurfaceContextAction) -> Void
    let onMoveDestination: (String) -> Void

    final class Coordinator {
        var snapshot: TabContextMenuSnapshot
        let actionTarget = TabContextMenuActionTarget()
        weak var view: NSView?
        var monitor: Any?

        init(snapshot: TabContextMenuSnapshot) {
            self.snapshot = snapshot
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func presentMenu(at point: NSPoint, in view: NSView) {
            let menu = TabContextMenuBuilder.makeMenu(snapshot: snapshot, target: actionTarget)
            menu.popUp(positioning: nil, at: point, in: view)
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(snapshot: snapshot)
        coordinator.actionTarget.onContextAction = onContextAction
        coordinator.actionTarget.onMoveDestination = onMoveDestination
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        context.coordinator.view = view

        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak coordinator] event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
            guard let coordinator, let view = coordinator.view, let window = view.window else { return event }
            guard event.window === window else { return event }

            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return event }

            coordinator.presentMenu(at: point, in: view)
            return nil
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.snapshot = snapshot
        context.coordinator.actionTarget.onContextAction = onContextAction
        context.coordinator.actionTarget.onMoveDestination = onMoveDestination
    }
}
