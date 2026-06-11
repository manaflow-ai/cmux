import AppKit
import Bonsplit
import Combine
import Observation
import SwiftUI


// MARK: - Titlebar controls SwiftUI view
@Observable
final class TitlebarControlsViewModel {
    weak var notificationsAnchorView: NSView?
}

private enum TitlebarControlIconStyle {
    static let opacity = HeaderChromeIconStyle.opacity
    static let hoveredOpacity = HeaderChromeIconStyle.hoveredOpacity
    static let pressedOpacity = HeaderChromeIconStyle.pressedOpacity
    static let weight = HeaderChromeIconStyle.weight
    static let foregroundColor = HeaderChromeIconStyle.foregroundColor
    static let sidebarGlyphStrokeWidth = HeaderChromeIconStyle.sidebarGlyphStrokeWidth

    static func iconFrameSize(for config: TitlebarControlsStyleConfig) -> CGFloat {
        HeaderChromeIconStyle.iconFrameSize(forIconSize: config.iconSize)
    }
}

struct TitlebarControlsView: View {
    let notificationStore: TerminalNotificationStore
    let viewModel: TitlebarControlsViewModel
    let onToggleSidebar: () -> Void
    let onToggleNotifications: () -> Void
    let onNewTab: () -> Void
    let onFocusHistoryBack: () -> Void
    let onFocusHistoryForward: () -> Void
    let visibilityMode: TitlebarControlsVisibilityMode
    private let popoverVisibilityState = NotificationsPopoverVisibilityState.shared
    @AppStorage("titlebarControlsStyle") private var styleRawValue = TitlebarControlsStyle.classic.rawValue
    @State private var shortcutRefreshTick = 0
    @State private var appearanceRefreshTick = 0
    @State private var isHoveringControls = false
    @State private var hostWindowNumber: Int?
    @State private var focusHistoryAvailabilityRevision: UInt64 = 0
    @State private var modifierKeyMonitor = TitlebarShortcutHintModifierMonitor()
    private let titlebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultTitlebarHintX
    private let titlebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultTitlebarHintY
    private let alwaysShowShortcutHints = ShortcutHintDebugSettings.alwaysShowHints()

    private struct TitlebarHintLayoutItem: Identifiable {
        let action: KeyboardShortcutSettings.Action
        let shortcut: StoredShortcut
        let width: CGFloat
        let centerX: CGFloat

        var id: String { action.rawValue }
    }

    private var shouldShowTitlebarShortcutHints: Bool {
        alwaysShowShortcutHints || modifierKeyMonitor.isModifierPressed
    }

    private var shouldShowControls: Bool {
        if visibilityMode == .alwaysVisible {
            return true
        }
        return isHoveringControls
            || popoverVisibilityState.isShown(in: hostWindowNumber)
            || shouldShowTitlebarShortcutHints
    }

    var body: some View {
        // Force the `.safeHelp(...)` tooltips to re-evaluate when shortcuts are changed in settings.
        // (The titlebar controls don't otherwise re-render on UserDefaults changes.)
        let _ = shortcutRefreshTick
        let _ = appearanceRefreshTick
        let style = TitlebarControlsStyle(rawValue: styleRawValue) ?? .classic
        let config = style.config
        let contentSize = TitlebarControlsLayoutMetrics.contentSize(
            config: config,
            titlebarShortcutHintXOffset: titlebarShortcutHintXOffset
        )
        let foregroundColor = Color(nsColor: titlebarControlForegroundNSColor(opacity: 1.0))
        controlsGroup(config: config, foregroundColor: foregroundColor)
            .padding(.leading, TitlebarControlsLayoutMetrics.hintLeadingPadding)
            .padding(.trailing, titlebarHintTrailingInset)
            .frame(width: contentSize.width, height: contentSize.height, alignment: .leading)
            .fixedSize()
            .contentShape(Rectangle())
            .opacity(shouldShowControls ? 1 : 0)
            .allowsHitTesting(shouldShowControls)
            .animation(.easeInOut(duration: 0.14), value: shouldShowControls)
            .background(
                WindowAccessor { window in
                    let nextWindowNumber = window.windowNumber
                    if hostWindowNumber != nextWindowNumber {
                        DispatchQueue.main.async {
                            if hostWindowNumber != nextWindowNumber {
                                hostWindowNumber = nextWindowNumber
                                focusHistoryAvailabilityRevision &+= 1
                            }
                        }
                    }
                    modifierKeyMonitor.setHostWindow(window)
                }
                .frame(width: 0, height: 0)
            )
            .onHover { hovering in
                isHoveringControls = hovering
            }
            .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutSettings.didChangeNotification)) { _ in
                shortcutRefreshTick &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .tabManagerFocusHistoryRevisionDidChange)) { _ in
                focusHistoryAvailabilityRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                focusHistoryAvailabilityRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
                appearanceRefreshTick &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
                appearanceRefreshTick &+= 1
            }
            .onAppear {
                modifierKeyMonitor.start()
            }
            .onDisappear {
                modifierKeyMonitor.stop()
                hostWindowNumber = nil
            }
    }

    private var titlebarHintTrailingInset: CGFloat {
        // Keep room for blur + shadow so the rightmost hint never clips.
        TitlebarControlsLayoutMetrics.hintTrailingInset(titlebarShortcutHintXOffset: titlebarShortcutHintXOffset)
    }

    private func titlebarHintVerticalBaseOffset(for config: TitlebarControlsStyleConfig) -> CGFloat {
        titlebarShortcutHintVerticalOffset(for: config)
    }

    @MainActor
    @ViewBuilder
    private func controlsGroup(config: TitlebarControlsStyleConfig, foregroundColor: Color) -> some View {
        let hintLayoutItems = titlebarHintLayoutItems(config: config)
        let focusHistoryAvailability = focusHistoryNavigationAvailabilitySnapshot
        let content = HStack(spacing: config.spacing) {
            TitlebarControlButton(
                config: config,
                foregroundColor: foregroundColor,
                accessibilityIdentifier: "titlebarControl.toggleSidebar",
                accessibilityLabel: String(localized: "titlebar.sidebar.accessibilityLabel", defaultValue: "Toggle Sidebar"),
                action: {
                #if DEBUG
                cmuxDebugLog("titlebar.toggleSidebar")
                #endif
                onToggleSidebar()
            },
                rightClickAction: { anchorView, event in
                    CmuxExtensionSidebarSelection.showMenu(anchorView: anchorView, event: event)
                }) {
                sidebarIconLabel(config: config, iconGeometryKeyPrefix: "titlebarControl_toggleSidebarIcon")
            }
            .safeHelp(KeyboardShortcutSettings.Action.toggleSidebar.tooltip(String(localized: "titlebar.sidebar.tooltip", defaultValue: "Show or hide the sidebar")))

            TitlebarControlButton(
                config: config,
                foregroundColor: foregroundColor,
                accessibilityIdentifier: "titlebarControl.showNotifications",
                accessibilityLabel: String(localized: "titlebar.notifications.accessibilityLabel", defaultValue: "Notifications"),
                action: {
                #if DEBUG
                cmuxDebugLog("titlebar.notifications")
                #endif
                onToggleNotifications()
            }) {
                ZStack(alignment: .topTrailing) {
                    iconLabel(
                        systemName: "bell",
                        config: config,
                        iconGeometryKeyPrefix: "titlebarControl_showNotificationsIcon"
                    )

                    if notificationStore.unreadCount > 0 {
                        Text("\(min(notificationStore.unreadCount, 99))")
                            .font(.system(size: titlebarNotificationBadgeFontSize(for: config), weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: config.badgeSize, height: config.badgeSize)
                            .background(
                                Circle().fill(cmuxAccentColor())
                            )
                            .offset(x: config.badgeOffset.width, y: config.badgeOffset.height)
                    }
                }
                .frame(width: config.buttonSize, height: config.buttonSize)
            }
            .background(NotificationsAnchorView { viewModel.notificationsAnchorView = $0 })
            .safeHelp(KeyboardShortcutSettings.Action.showNotifications.tooltip(String(localized: "titlebar.notifications.tooltip", defaultValue: "Show notifications")))

            TitlebarControlButton(
                config: config,
                foregroundColor: foregroundColor,
                accessibilityIdentifier: "titlebarControl.newTab",
                accessibilityLabel: String(localized: "titlebar.newWorkspace.accessibilityLabel", defaultValue: "New Workspace"),
                action: {
                #if DEBUG
                cmuxDebugLog("titlebar.newTab")
                #endif
                onNewTab()
            },
                rightClickAction: { anchorView, event in
                    _ = AppDelegate.shared?.showNewWorkspaceContextMenu(anchorView: anchorView, event: event)
                }) {
                iconLabel(systemName: "plus", config: config, iconGeometryKeyPrefix: "titlebarControl_newTabIcon")
            }
            .safeHelp(KeyboardShortcutSettings.Action.newTab.tooltip(String(localized: "titlebar.newWorkspace.tooltip", defaultValue: "New workspace")))

            TitlebarControlButton(
                config: config,
                foregroundColor: foregroundColor,
                accessibilityIdentifier: "titlebarControl.focusHistoryBack",
                accessibilityLabel: String(localized: "menu.history.focusBack", defaultValue: "Focus Back"),
                action: onFocusHistoryBack,
                isEnabled: focusHistoryAvailability.canNavigateBack,
                rightClickAction: { anchorView, event in
                    _ = AppDelegate.shared?.showFocusHistoryContextMenu(anchorView: anchorView, event: event, direction: .back)
                }
            ) {
                iconLabel(systemName: "arrow.left", config: config, iconGeometryKeyPrefix: "titlebarControl_focusHistoryBackIcon")
            }
            .safeHelp(KeyboardShortcutSettings.Action.focusHistoryBack.tooltip(String(localized: "menu.history.focusBack", defaultValue: "Focus Back")))

            TitlebarControlButton(
                config: config,
                foregroundColor: foregroundColor,
                accessibilityIdentifier: "titlebarControl.focusHistoryForward",
                accessibilityLabel: String(localized: "menu.history.focusForward", defaultValue: "Focus Forward"),
                action: onFocusHistoryForward,
                isEnabled: focusHistoryAvailability.canNavigateForward,
                rightClickAction: { anchorView, event in
                    _ = AppDelegate.shared?.showFocusHistoryContextMenu(anchorView: anchorView, event: event, direction: .forward)
                }
            ) {
                iconLabel(systemName: "arrow.right", config: config, iconGeometryKeyPrefix: "titlebarControl_focusHistoryForwardIcon")
            }
            .safeHelp(KeyboardShortcutSettings.Action.focusHistoryForward.tooltip(String(localized: "menu.history.focusForward", defaultValue: "Focus Forward")))

        }

        let paddedContent = content.padding(config.groupPadding)

        if config.groupBackground {
            paddedContent
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    titlebarShortcutHintOverlay(items: hintLayoutItems, config: config)
                }
        } else {
            paddedContent
                .overlay(alignment: .topLeading) {
                    titlebarShortcutHintOverlay(items: hintLayoutItems, config: config)
                }
        }
    }

    @MainActor
    private var focusHistoryNavigationAvailabilitySnapshot: FocusHistoryNavigationAvailability {
        let _ = focusHistoryAvailabilityRevision
        return focusHistoryNavigationAvailability(preferredWindow: focusHistoryTargetWindow)
    }

    @MainActor
    private var focusHistoryTargetWindow: NSWindow? {
        if let hostWindowNumber,
           let hostWindow = NSApp.windows.first(where: { $0.windowNumber == hostWindowNumber }) {
            return hostWindow
        }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func titlebarHintLayoutItems(config: TitlebarControlsStyleConfig) -> [TitlebarHintLayoutItem] {
        let xOffset = CGFloat(ShortcutHintDebugSettings.clamped(titlebarShortcutHintXOffset))
        let intervals = titlebarHintIntervals(config: config, xOffset: xOffset)
        guard !intervals.isEmpty else { return [] }

        var items: [TitlebarHintLayoutItem] = []
        items.reserveCapacity(intervals.count)
        for item in intervals {
            items.append(
                TitlebarHintLayoutItem(
                    action: item.action,
                    shortcut: item.shortcut,
                    width: item.width,
                    centerX: (item.interval.lowerBound + item.interval.upperBound) / 2.0
                )
            )
        }
        return items
    }

    private func titlebarHintIntervals(
        config: TitlebarControlsStyleConfig,
        xOffset: CGFloat
    ) -> [(action: KeyboardShortcutSettings.Action, shortcut: StoredShortcut, width: CGFloat, interval: ClosedRange<CGFloat>)] {
        guard shouldShowTitlebarShortcutHints else { return [] }

        return TitlebarShortcutHintActionSlot.allCases.compactMap { slot in
            let shortcut = KeyboardShortcutSettings.shortcut(for: slot.action)
            guard titlebarShortcutHintShouldShow(
                shortcut: shortcut,
                alwaysShowShortcutHints: alwaysShowShortcutHints,
                modifierPressed: modifierKeyMonitor.isModifierPressed
            ) else { return nil }

            let width = titlebarHintWidth(for: shortcut, config: config)
            let interval = TitlebarControlsLayoutMetrics.hintInterval(
                for: slot,
                width: width,
                config: config,
                xOffset: xOffset
            )
            return (slot.action, shortcut, width, interval)
        }
    }

    private func titlebarHintWidth(for shortcut: StoredShortcut, config: TitlebarControlsStyleConfig) -> CGFloat {
        titlebarHintPillWidth(for: shortcut, config: config)
    }

    @ViewBuilder
    private func titlebarShortcutHintOverlay(
        items: [TitlebarHintLayoutItem],
        config: TitlebarControlsStyleConfig
    ) -> some View {
        let yOffset = config.groupPadding.top
            + titlebarHintVerticalBaseOffset(for: config)
            + ShortcutHintDebugSettings.clamped(titlebarShortcutHintYOffset)

        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(items) { item in
                titlebarShortcutHintPill(shortcut: item.shortcut, config: config)
                    .accessibilityIdentifier("titlebarShortcutHint.\(item.action.rawValue)")
                    .frame(width: item.width, alignment: .center)
                    .background(TitlebarChromeGeometryReporter(keyPrefix: "titlebarShortcutHint_\(item.action.rawValue)"))
                    .position(
                        x: item.centerX,
                        y: yOffset + titlebarShortcutHintHeight(for: config) / 2.0
                    )
                    .shortcutHintTransition()
            }
        }
        .shortcutHintVisibilityAnimation(value: shouldShowTitlebarShortcutHints)
        .allowsHitTesting(false)
    }

    private func titlebarShortcutHintPill(
        shortcut: StoredShortcut,
        config: TitlebarControlsStyleConfig
    ) -> some View {
        ShortcutHintPill(shortcut: shortcut, fontSize: max(8, config.iconSize - 5))
            .frame(minHeight: titlebarShortcutHintHeight(for: config))
    }

    @ViewBuilder
    private func iconLabel(
        systemName: String,
        config: TitlebarControlsStyleConfig,
        iconGeometryKeyPrefix: String? = nil
    ) -> some View {
        titlebarIconChrome(config: config, iconGeometryKeyPrefix: iconGeometryKeyPrefix) {
            Image(systemName: systemName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: config.iconSize, weight: TitlebarControlIconStyle.weight))
        }
    }

    @ViewBuilder
    private func sidebarIconLabel(
        config: TitlebarControlsStyleConfig,
        iconGeometryKeyPrefix: String? = nil
    ) -> some View {
        titlebarIconChrome(config: config, iconGeometryKeyPrefix: iconGeometryKeyPrefix) {
            TitlebarSidebarGlyph(iconSize: config.iconSize)
        }
    }

    @ViewBuilder
    private func titlebarIconChrome<Icon: View>(
        config: TitlebarControlsStyleConfig,
        iconGeometryKeyPrefix: String? = nil,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        icon()
            .frame(
                width: TitlebarControlIconStyle.iconFrameSize(for: config),
                height: TitlebarControlIconStyle.iconFrameSize(for: config)
            )
            .background(TitlebarChromeGeometryReporter(keyPrefix: iconGeometryKeyPrefix ?? ""))
    }
}

private struct TitlebarSidebarGlyph: View {
    let iconSize: CGFloat

    var body: some View {
        TitlebarSidebarGlyphShape()
            .stroke(
                style: StrokeStyle(
                    lineWidth: TitlebarControlIconStyle.sidebarGlyphStrokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: max(13, iconSize + 2), height: max(11, iconSize - 1))
    }
}

private struct TitlebarSidebarGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let insetRect = rect.insetBy(dx: 0.5, dy: 0.5)
        path.addRoundedRect(
            in: insetRect,
            cornerSize: CGSize(width: 2, height: 2)
        )

        let dividerX = insetRect.minX + insetRect.width * 0.36
        path.move(to: CGPoint(x: dividerX, y: insetRect.minY + 1.5))
        path.addLine(to: CGPoint(x: dividerX, y: insetRect.maxY - 1.5))
        return path
    }
}

@MainActor
@Observable
private final class TitlebarShortcutHintModifierMonitor {
    private(set) var isModifierPressed = false {
        didSet {
            guard oldValue != isModifierPressed else { return }
            NotificationCenter.default.post(
                name: .titlebarShortcutHintsVisibilityChanged,
                object: nil,
                userInfo: ["visible": isModifierPressed]
            )
        }
    }

    private weak var hostWindow: NSWindow?
    private var hostWindowDidBecomeKeyObserver: NSObjectProtocol?
    private var hostWindowDidResignKeyObserver: NSObjectProtocol?
    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var appResignObserver: NSObjectProtocol?
    private var pendingShowWorkItem: DispatchWorkItem?

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
            self?.handleKeyDown(event)
            return event
        }

        appResignObserver = NotificationCenter.default.addObserver(
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
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        removeHostWindowObservers()
        cancelPendingHintShow(resetVisible: true)
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard isCurrentWindow(eventWindow: event.window) else { return }
        cancelPendingHintShow(resetVisible: true)
    }

    private func isCurrentWindow(eventWindow: NSWindow?) -> Bool {
        ShortcutHintModifierPolicy.isCurrentWindow(
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        )
    }

    private func update(from modifierFlags: NSEvent.ModifierFlags, eventWindow: NSWindow?) {
        guard ShortcutHintModifierPolicy.shouldShowCommandHints(for: modifierFlags),
              ShortcutHintModifierPolicy.isCurrentWindow(
                hostWindowNumber: hostWindow?.windowNumber,
                hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
                eventWindowNumber: eventWindow?.windowNumber,
                keyWindowNumber: NSApp.keyWindow?.windowNumber
              ) else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        queueHintShow()
    }

    private func queueHintShow() {
        if pendingShowWorkItem != nil || isModifierPressed {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShowWorkItem = nil
            guard ShortcutHintModifierPolicy.shouldShowCommandHints(for: NSEvent.modifierFlags),
                  ShortcutHintModifierPolicy.isCurrentWindow(
                    hostWindowNumber: self.hostWindow?.windowNumber,
                    hostWindowIsKey: self.hostWindow?.isKeyWindow ?? false,
                    eventWindowNumber: nil,
                    keyWindowNumber: NSApp.keyWindow?.windowNumber
                  ) else { return }
            self.isModifierPressed = true
        }

        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ShortcutHintModifierPolicy.intentionalHoldDelay, execute: workItem)
    }

    private func cancelPendingHintShow(resetVisible: Bool) {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        if resetVisible {
            isModifierPressed = false
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

