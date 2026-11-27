import AppKit
import ApplicationServices

/// Reads where the first app list of the System Settings pane ends (the AX tree; a fake in tests).
protocol SettingsListReading: AnyObject {
    /// The bottom of the pane's first app list, in points from the top edge of `window`,
    /// or nil when it cannot be read.
    func firstListBottom(in window: SettingsWindowMatch) async -> CGFloat?
}

/// The cmux app's own Accessibility view of System Settings, read off the main thread.
final class LiveSettingsListReader: SettingsListReading {
    func firstListBottom(in window: SettingsWindowMatch) async -> CGFloat? {
        await SystemSettingsList.firstListBottom(in: window)
    }
}

/// The first app list of a Privacy & Security pane, from System Settings' AX tree.
///
/// The Screen & System Audio Recording pane has two lists, "Screen & System Audio Recording" and
/// "System Audio Recording Only" under it, and the first one grows with its apps. The drag panel
/// docks under the first one, so its arrow points into it.
///
/// - Source: the cmux app's own Accessibility grant, only when `AXIsProcessTrusted()` is
///   already true (it never prompts). The helper holds the grant too, but its one AX read
///   (`get_window_state`) is a tool call that records a session in Agent Activity, and its
///   host-only methods read windows, not elements; so the helper is not asked.
/// - Cost: the walk goes into groups, scroll areas and split groups right of the sidebar
///   only, never into rows: about 3 ms (the first read about 60 ms) on macOS 26.6. Each AX
///   message waits at most ``timeout``; the walk gives up after ``budget`` elements or
///   ``deadline``, so a hung System Settings costs a background thread half a second, never the main thread.
/// - Shape on macOS 26.6: window > ... > scroll area (the pane) > group (one list: a scroll
///   area holding an `AXOutline` of 40 pt rows, and the list's +/- buttons under it).
nonisolated enum SystemSettingsList {
    /// The longest wait for one AX message to System Settings, in seconds.
    static let timeout: Float = 0.25
    /// Elements visited before the walk gives up.
    static let budget = 200
    /// Time the whole walk may take.
    static let deadline: Duration = .milliseconds(500)
    /// Levels below the window the walk goes down (the list's outline is 8 down on macOS 26.6).
    static let depth = 10
    /// Room under the outline for the list's +/- buttons, when the group around them is not found.
    static let footer: CGFloat = 24

    @concurrent static func firstListBottom(in window: SettingsWindowMatch) async -> CGFloat? {
        guard window.pid > 0, AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let end = ContinuousClock.now + deadline
        guard let axWindow = matchingWindow(of: app, bounds: window.bounds),
              let bottom = firstListBottom(of: axWindow, contentMinX: window.bounds.minX + SystemSettingsWindow.listLeading, end: end)
        else { return nil }
        return bottom - window.bounds.minY
    }

    /// The AX window at `bounds` (the window list's frame), or the first window.
    private static func matchingWindow(of app: AXUIElement, bounds: CGRect) -> AXUIElement? {
        let windows = elements(app, kAXWindowsAttribute)
        let match = windows.first { frame(of: $0).map { abs($0.minX - bounds.minX) < 2 && abs($0.minY - bounds.minY) < 2 } ?? false }
        return match ?? windows.first
    }

    /// The bottom (top-left screen points) of the topmost list right of the sidebar.
    private static func firstListBottom(of window: AXUIElement, contentMinX: CGFloat, end: ContinuousClock.Instant) -> CGFloat? {
        var level = [window]
        var visited = 0
        var lists: [(element: AXUIElement, frame: CGRect)] = []
        // Breadth first: both lists of a pane sit at the same depth, so the walk stops at the first level that has one.
        for _ in 0..<depth where lists.isEmpty && !level.isEmpty {
            var next: [AXUIElement] = []
            for element in level {
                for child in elements(element, kAXChildrenAttribute) {
                    visited += 1
                    guard visited <= budget, ContinuousClock.now < end else { return nil }
                    let role = string(child, kAXRoleAttribute)
                    let isList = listRoles.contains(role)
                    guard isList || containerRoles.contains(role),
                          let box = frame(of: child), box.maxX > contentMinX - 8 else { continue }
                    if !isList {
                        next.append(child)
                    } else if box.minX >= contentMinX - 8 {
                        lists.append((child, box))
                    }
                }
            }
            level = next
        }
        guard let first = lists.min(by: { $0.frame.minY < $1.frame.minY }) else { return nil }
        return groupBottom(of: first.element, list: first.frame)
    }

    /// The list's group (outline > scroll area > group) holds its +/- buttons: its bottom is the list's.
    private static func groupBottom(of list: AXUIElement, list box: CGRect) -> CGFloat {
        if let scroll = parent(of: list), let group = parent(of: scroll), string(group, kAXRoleAttribute) == kAXGroupRole,
           let frame = frame(of: group), frame.minY <= box.minY + 1, frame.height - box.height <= 2 * footer {
            return frame.maxY
        }
        return box.maxY + footer
    }

    private static let listRoles: Set<String> = [kAXOutlineRole, kAXTableRole, kAXListRole]
    private static let containerRoles: Set<String> = [kAXGroupRole, kAXScrollAreaRole, kAXSplitGroupRole]

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(element, attribute) as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        value(element, attribute) as? String ?? ""
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let parent = value(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(parent, to: AXUIElement.self)
    }

    /// Top-left screen points, as the window list's bounds.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = axValue(value(element, kAXPositionAttribute)), let size = axValue(value(element, kAXSizeAttribute)) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// The value as an AXValue when its CoreFoundation type is one (nil otherwise).
    private static func axValue(_ value: AnyObject?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }
}
