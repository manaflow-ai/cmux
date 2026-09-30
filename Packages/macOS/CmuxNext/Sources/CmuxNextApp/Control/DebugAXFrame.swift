#if DEBUG
import AppKit
import ApplicationServices
import CmuxNextSettings

/// `debug.window.ax_set_frame` (DEBUG builds): moves and resizes one of this
/// app's own windows through the Accessibility API, the way Rectangle does
/// (AXPosition, then AXSize, as separate calls, with the app inactive), and
/// checks `ChildPageGeometry` after every call. Only this process's windows
/// are touched. The AX calls run off the main actor: the main thread must be
/// free to serve them.
///
/// Params: `frames`: [[x, y, w, h], ...] in AX coordinates (top-left origin
/// of the primary display, points), applied in order; or `snap`: "left" |
/// "right" | "full" with optional `screen` (index or "last"). `window`
/// selects a cmux window id. `order`: "position_size" (default, Rectangle)
/// or "size_position".
enum DebugAXFrame {
    struct Target: Sendable {
        var frame: CGRect
        var windowID: String
        var pid: pid_t
        /// What the app reports as its AX focused and main window, and the
        /// AX windows it lists (role/subrole), before the calls.
        var report: [String: JSONValue] = [:]
    }

    static func run(_ params: [String: JSONValue], services: AppServices) async -> JSONValue {
        guard let (target, frames) = await MainActor.run(body: { plan(params, services: services) }) else {
            return .object(["error": .string("no window or no frames")])
        }
        guard let element = axWindow(pid: target.pid, matching: target.frame) else {
            return .object(["error": .string("AX window not found"), "trusted": .bool(AXIsProcessTrusted())])
        }
        var windows: [JSONValue] = []
        let app = AXUIElementCreateApplication(target.pid)
        var list: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list) == .success, let elements = list as? [AXUIElement] {
            windows = elements.map { .string("\(string($0, kAXRoleAttribute)) \(string($0, kAXSubroleAttribute)) \(axFrame($0))") }
        }
        var focused: CFTypeRef?
        let focusedFrame = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success
            ? focused.map { "\(axFrame($0 as! AXUIElement))" } : nil
        let sizeFirst = params["order"]?.stringValue == "size_position"
        var steps: [JSONValue] = []
        var allInSync = true
        for frame in frames {
            let calls: [(String, CGRect)] = sizeFirst ? [("size", frame), ("position", frame)] : [("position", frame), ("size", frame)]
            for (attribute, value) in calls {
                let error = set(element, attribute: attribute, frame: value)
                // The AX request ran on the main thread before it returned.
                let immediate = await MainActor.run { sample(services, windowID: target.windowID) }
                // Then whatever the main actor had queued behind it (layout,
                // notifications posted with a run-loop delay).
                await MainActor.run {}
                let settled = await MainActor.run { sample(services, windowID: target.windowID) }
                if !(immediate.problems.isEmpty && settled.problems.isEmpty) { allInSync = false }
                steps.append(.object([
                    "set": .string(attribute), "value": rect(value), "ax_error": .number(Double(error.rawValue)),
                    "window_frame": rect(immediate.windowFrame),
                    "immediate": .array(immediate.problems.map(JSONValue.string)),
                    "settled": .array(settled.problems.map(JSONValue.string)),
                    "hosts": .number(Double(settled.hosts)),
                ]))
            }
        }
        return .object(["steps": .array(steps), "in_sync": .bool(allInSync), "trusted": .bool(AXIsProcessTrusted()),
                        "ax_windows": .array(windows), "ax_focused_window": focusedFrame.map(JSONValue.string) ?? .null])
    }

    @MainActor
    private static func plan(_ params: [String: JSONValue], services: AppServices) -> (Target, [CGRect])? {
        let windowID = params["window"]?.stringValue
        guard let controller = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID }),
              let window = controller.window else { return nil }
        var frames: [CGRect] = (params["frames"]?.arrayValue ?? []).compactMap { value in
            guard let numbers = value.arrayValue?.compactMap(\.doubleValue), numbers.count == 4 else { return nil }
            return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }
        if let snap = params["snap"]?.stringValue {
            let screens = NSScreen.screens
            let index = params["screen"]?.stringValue == "last" ? screens.count - 1 : (params["screen"]?.intValue ?? screens.firstIndex { $0 === window.screen } ?? 0)
            guard screens.indices.contains(index) else { return nil }
            var visible = screens[index].visibleFrame
            switch snap {
            case "left": visible.size.width /= 2
            case "right": visible.origin.x += visible.width / 2; visible.size.width /= 2
            default: break
            }
            frames.append(axRect(visible))
        }
        guard !frames.isEmpty else { return nil }
        // `"target": "page"`: the Chromium page window of the focused pane,
        // as an AX client that asks for the key (focused) window gets it
        // while the page has the keyboard.
        var frame = window.frame
        if params["target"]?.stringValue == "page" {
            guard let page = WindowOverlayLayer.contentChildWindows(of: window).first else { return nil }
            frame = page.frame
        }
        return (Target(frame: axRect(frame), windowID: controller.state.id, pid: getpid()), frames)
    }

    /// AppKit screen rect (bottom-left origin) -> AX rect (top-left origin of
    /// the primary display).
    @MainActor
    static func axRect(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func axWindow(pid: pid_t, matching frame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.min { distance(axFrame($0), frame) < distance(axFrame($1), frame) }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "-" }
        return (value as? String) ?? "-"
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect {
        var position = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success, let value {
            AXValueGetValue(value as! AXValue, .cgPoint, &position)
        }
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success, let value {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private static func set(_ element: AXUIElement, attribute: String, frame: CGRect) -> AXError {
        if attribute == "position" {
            var point = frame.origin
            guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
            return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
        var size = frame.size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    struct Sample: Sendable {
        var windowFrame: CGRect
        var problems: [String]
        var hosts: Int
    }

    @MainActor
    private static func sample(_ services: AppServices, windowID: String) -> Sample {
        guard let controller = services.windows.controllers.first(where: { $0.state.id == windowID }) else {
            return Sample(windowFrame: .zero, problems: ["window gone"], hosts: 0)
        }
        let (hosts, pages) = ChildPageGeometry.sample(controller)
        return Sample(windowFrame: controller.window?.frame ?? .zero, problems: ChildPageGeometry.mismatches(hosts: hosts, pages: pages),
                      hosts: hosts.count)
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        .array([rect.minX, rect.minY, rect.width, rect.height].map { .number(Double($0)) })
    }
}
#endif
