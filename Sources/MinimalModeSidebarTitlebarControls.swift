import AppKit
import Bonsplit
import Observation
import SwiftUI


// MARK: - Minimal-mode sidebar titlebar control slots, availability, and chrome hover
enum MinimalModeSidebarControlActionSlot: Int, CaseIterable {
    case toggleSidebar
    case showNotifications
    case newTab
    case focusHistoryBack
    case focusHistoryForward

    var accessibilityIdentifier: String {
        switch self {
        case .toggleSidebar:
            return "titlebarControl.toggleSidebar"
        case .showNotifications:
            return "titlebarControl.showNotifications"
        case .newTab:
            return "titlebarControl.newTab"
        case .focusHistoryBack:
            return "titlebarControl.focusHistoryBack"
        case .focusHistoryForward:
            return "titlebarControl.focusHistoryForward"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .toggleSidebar:
            return String(localized: "titlebar.sidebar.accessibilityLabel", defaultValue: "Toggle Sidebar")
        case .showNotifications:
            return String(localized: "titlebar.notifications.accessibilityLabel", defaultValue: "Notifications")
        case .newTab:
            return String(localized: "titlebar.newWorkspace.accessibilityLabel", defaultValue: "New Workspace")
        case .focusHistoryBack:
            return String(localized: "menu.history.focusBack", defaultValue: "Focus Back")
        case .focusHistoryForward:
            return String(localized: "menu.history.focusForward", defaultValue: "Focus Forward")
        }
    }

    var debugName: String {
        switch self {
        case .toggleSidebar:
            return "toggleSidebar"
        case .showNotifications:
            return "showNotifications"
        case .newTab:
            return "newTab"
        case .focusHistoryBack:
            return "focusHistoryBack"
        case .focusHistoryForward:
            return "focusHistoryForward"
        }
    }

    var acceptsContextMenu: Bool {
        switch self {
        case .toggleSidebar, .newTab, .focusHistoryBack, .focusHistoryForward:
            return true
        case .showNotifications:
            return false
        }
    }
}

@Observable
final class MinimalModeSidebarChromeHoverState {
    static let shared = MinimalModeSidebarChromeHoverState()

    private(set) var hoveredWindowNumber: Int?

    private init() {}

    func setHovering(_ isHovering: Bool, windowNumber: Int) {
        if isHovering {
            guard hoveredWindowNumber != windowNumber else { return }
            hoveredWindowNumber = windowNumber
        } else if hoveredWindowNumber == windowNumber {
            hoveredWindowNumber = nil
        }
    }

    func clear() {
        guard hoveredWindowNumber != nil else { return }
        hoveredWindowNumber = nil
    }
}

private enum MinimalModeSidebarTitlebarControlAssociatedKeys {
    private static let sidebarVisibleToken = NSObject()

    static let sidebarVisible = UnsafeRawPointer(Unmanaged.passUnretained(sidebarVisibleToken).toOpaque())
}

func setMinimalModeSidebarTitlebarControlsAvailable(_ isAvailable: Bool, in window: NSWindow?) {
    guard let window else { return }
    objc_setAssociatedObject(
        window,
        MinimalModeSidebarTitlebarControlAssociatedKeys.sidebarVisible,
        NSNumber(value: isAvailable),
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
}

func minimalModeSidebarTitlebarControlsAreAvailable(in window: NSWindow) -> Bool {
    guard let value = objc_getAssociatedObject(
        window,
        MinimalModeSidebarTitlebarControlAssociatedKeys.sidebarVisible
    ) as? NSNumber else {
        return true
    }
    return value.boolValue
}

func isMinimalModeSidebarChromeHoverCandidate(
    window: NSWindow,
    locationInWindow: NSPoint,
    defaults: UserDefaults = .standard
) -> Bool {
    let contentBounds = window.contentView?.bounds ?? NSRect(
        x: 0,
        y: 0,
        width: window.frame.width,
        height: window.frame.height
    )
    let isMinimalMode = WorkspacePresentationModeSettings.isMinimal(defaults: defaults)
    let isFullScreen = window.styleMask.contains(.fullScreen)
    let isMainWindow = isMainWorkspaceWindow(window)
    guard isMinimalMode, !isFullScreen, isMainWindow, contentBounds.contains(locationInWindow) else {
        return false
    }
    guard minimalModeSidebarTitlebarControlsAreAvailable(in: window) else {
        return false
    }

    if MinimalModeTitlebarControlHitRegionRegistry.containsSidebarControlHostWindowPoint(
        locationInWindow,
        in: window
    ) {
        return true
    }

    guard isPointInMinimalModeTitlebarBand(
        isEnabled: true,
        point: locationInWindow,
        bounds: contentBounds,
        topStripHeight: MinimalModeChromeMetrics.titlebarHeight
    ) else { return false }

    let minX = MinimalModeSidebarTitlebarControlsMetrics.leadingInset(defaults: defaults)
    let maxX = minX + MinimalModeSidebarTitlebarControlsMetrics.hostWidth
    return locationInWindow.x >= minX && locationInWindow.x <= maxX
}

private func titlebarControlsStyleConfig(defaults: UserDefaults) -> TitlebarControlsStyleConfig {
    let style = TitlebarControlsStyle(rawValue: defaults.integer(forKey: "titlebarControlsStyle")) ?? .classic
    return style.config
}

func minimalModeSidebarControlActionSlot(
    window: NSWindow,
    locationInWindow: NSPoint,
    defaults: UserDefaults = .standard
) -> MinimalModeSidebarControlActionSlot? {
    let contentBounds = window.contentView?.bounds ?? NSRect(
        x: 0,
        y: 0,
        width: window.frame.width,
        height: window.frame.height
    )
    let isMinimalMode = WorkspacePresentationModeSettings.isMinimal(defaults: defaults)
    let isFullScreen = window.styleMask.contains(.fullScreen)
    let isMainWindow = isMainWorkspaceWindow(window)
    guard isMinimalMode, !isFullScreen, isMainWindow, contentBounds.contains(locationInWindow) else {
        return nil
    }
    guard minimalModeSidebarTitlebarControlsAreAvailable(in: window) else {
        return nil
    }

    if let registeredSlot = MinimalModeTitlebarControlHitRegionRegistry.minimalModeSidebarControlActionSlot(
        forWindowPoint: locationInWindow,
        in: window
    ) {
        return registeredSlot
    }

    guard isPointInMinimalModeTitlebarBand(
        isEnabled: true,
        point: locationInWindow,
        bounds: contentBounds,
        topStripHeight: MinimalModeChromeMetrics.titlebarHeight
    ) else { return nil }

    let leadingInset = MinimalModeSidebarTitlebarControlsMetrics.leadingInset(defaults: defaults)
    let localPoint = NSPoint(
        x: locationInWindow.x - leadingInset,
        y: MinimalModeSidebarTitlebarControlsMetrics.hostHeight / 2
    )
    return TitlebarControlsHitRegions.sidebarActionSlot(
        at: localPoint,
        config: titlebarControlsStyleConfig(defaults: defaults)
    )
}

func isMinimalModeSidebarTitlebarControlButtonHit(
    window: NSWindow,
    locationInWindow: NSPoint,
    defaults: UserDefaults = .standard
) -> Bool {
    minimalModeSidebarControlActionSlot(
        window: window,
        locationInWindow: locationInWindow,
        defaults: defaults
    ) != nil
}

#if DEBUG
func recordMinimalModeSidebarChromeHoverForUITest(
    window: NSWindow,
    locationInWindow: NSPoint,
    isHovering: Bool,
    eventType: NSEvent.EventType
) {
    let env = ProcessInfo.processInfo.environment
    guard env["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" else { return }
    let defaults = UserDefaults.standard
    let isMinimal = WorkspacePresentationModeSettings.isMinimal(defaults: defaults)
    let isFullScreen = window.styleMask.contains(.fullScreen)
    let isMainWindow = isMainWorkspaceWindow(window)
    let sidebarControlsAvailable = minimalModeSidebarTitlebarControlsAreAvailable(in: window)
    let contentBounds = window.contentView?.bounds ?? .zero
    let inTitlebarBand = isMinimalModeWindowTitlebarClickCandidate(
        isMinimalMode: isMinimal,
        isFullScreen: isFullScreen,
        isMainWindow: isMainWindow,
        locationInWindow: locationInWindow,
        contentBounds: contentBounds,
        titlebarBandHeight: MinimalModeChromeMetrics.titlebarHeight
    )
    let minX = MinimalModeSidebarTitlebarControlsMetrics.leadingInset
    let maxX = minX + MinimalModeSidebarTitlebarControlsMetrics.hostWidth
    let inXRange = (locationInWindow.x >= minX && locationInWindow.x <= maxX)
        || MinimalModeTitlebarControlHitRegionRegistry.containsSidebarControlHostWindowPoint(
            locationInWindow,
            in: window
        )
    _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
        let count = (payload["minimalSidebarHoverEventCount"] as? String).flatMap(Int.init) ?? 0
        payload["minimalSidebarHoverEventCount"] = String(count + 1)
        payload["minimalSidebarHoverEventType"] = String(describing: eventType)
        payload["minimalSidebarHoverWindowNumber"] = String(window.windowNumber)
        payload["minimalSidebarHoverPoint"] = windowDragHandleFormatPoint(locationInWindow)
        payload["minimalSidebarHoverIsCandidate"] = String(isHovering)
        payload["minimalSidebarHoverIsMinimal"] = String(isMinimal)
        payload["minimalSidebarHoverIsFullScreen"] = String(isFullScreen)
        payload["minimalSidebarHoverIsMainWindow"] = String(isMainWindow)
        payload["minimalSidebarHoverSidebarControlsAvailable"] = String(sidebarControlsAvailable)
        payload["minimalSidebarHoverInTitlebarBand"] = String(inTitlebarBand)
        payload["minimalSidebarHoverInXRange"] = String(inXRange)
        payload["minimalSidebarHoverContentBounds"] = NSStringFromRect(contentBounds)
    }
}
#endif

