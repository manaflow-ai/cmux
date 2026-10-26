#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import ApplicationServices
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups

/// `debug.window.ax_set_frame` (DEBUG builds): moves and resizes one of this
/// app's own windows through the Accessibility API, the way Rectangle does
/// (AXPosition, then AXSize, as separate calls, with the app inactive), and
/// checks `ChildPageGeometry` after every call. Only this process's windows
/// are touched. The AX calls (``AXWindowFrame``) run on the system lane, never
/// on the main thread: it must be free to serve them.
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
        guard let (target, frames) = plan(params, services: services) else {
            return .object(["error": .string("no window or no frames")])
        }
        // A person ran the debug command and waits for it.
        let (work, pid, wanted) = (services.work, target.pid, target.frame)
        let trusted = (try? await work.run(.userBlocking, mayBlock: .system) { AXIsProcessTrusted() }) ?? false
        guard let element = try? await work.run(.userBlocking, mayBlock: .system, { () throws -> AXWindowFrame? in AXWindowFrame(pid: pid, nearest: wanted) }) else {
            return .object(["error": .string("AX window not found"), "trusted": .bool(trusted)])
        }
        let sizeFirst = params["order"]?.stringValue == "size_position"
        var steps: [JSONValue] = []
        var allInSync = true
        for frame in frames {
            let calls: [(String, CGRect)] = sizeFirst ? [("size", frame), ("position", frame)] : [("position", frame), ("size", frame)]
            for (attribute, value) in calls {
                let error = (try? await work.run(.userBlocking, mayBlock: .system) { element.set(attribute, from: value) }) ?? .failure
                // The AX request ran on the main thread before it returned.
                let immediate = sample(services, windowID: target.windowID)
                // Then whatever the main thread had queued behind it (layout,
                // notifications posted with a run-loop delay): a posted task
                // runs on a later turn, after the work posted before it.
                let settled = await services.mainWork.apply(.automation, owner: "debug.ax_set_frame.settled") {
                    sample(services, windowID: target.windowID)
                }
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
        return .object(["steps": .array(steps), "in_sync": .bool(allInSync), "trusted": .bool(trusted),
                        "ax_windows": .array(element.windows.map(JSONValue.string)),
                        "ax_focused_window": element.focusedFrame.map(JSONValue.string) ?? .null])
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
        // The focus ring (overlay plane, possibly above the pages) must
        // stroke its pane's rounded content rect after every call too.
        let rings = (controller.content?.layoutView.overlayRings ?? []).filter { $0.showsRing && !$0.ringInSync }
            .map { "ring \($0.pane) at \($0.ringInWindow), pane content at \($0.contentInWindow)" }
        return Sample(windowFrame: controller.window?.frame ?? .zero,
                      problems: ChildPageGeometry.mismatches(hosts: hosts, pages: pages) + rings, hosts: hosts.count)
    }

    private static func rect(_ rect: CGRect) -> JSONValue {
        .array([rect.minX, rect.minY, rect.width, rect.height].map { .number(Double($0)) })
    }
}
#endif
