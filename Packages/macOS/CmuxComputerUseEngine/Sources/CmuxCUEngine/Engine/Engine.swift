// SPDX-License-Identifier: GPL-3.0-or-later
@preconcurrency import ApplicationServices
import Foundation

/// What a tool call returns: MCP content blocks.
struct ToolResult: Sendable {
    enum Block: Sendable {
        case text(String)
        case jpeg(Data)
    }

    var blocks: [Block]
    var isError = false
    var timings: [String: Double] = [:]

    static func error(_ message: String) -> ToolResult { ToolResult(blocks: [.text(message)], isError: true) }
}

struct EngineError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The Computer Use engine. Every acting tool ends with the app's settled
/// state (tree + screenshot) in the same reply, so an agent turn is one
/// round trip: act, then read what happened, without a second call.
public final class Engine: @unchecked Sendable {
    let directory = AppDirectory()
    let sessions = AppSessions()
    let capture = WindowCapture()
    let encoder = JPEGEncoder()
    let monitor = AppActivityMonitor()
    let input = InputSynth()
    let renderer = TreeRenderer()
    var walker = AXTreeWalker()
    var settle = SettlePolicy()
    /// Long edge of the screenshot, in pixels (Codex caps near this too).
    var maxImageEdge = 1568

    public init() {}

    // MARK: Observe

    func listApps() -> ToolResult {
        let lines = directory.runningApps().map { app in
            var line = "\(app.name) — \(app.path ?? "") — \(app.bundleID ?? "") [running"
            if app.isActive { line += ", frontmost" }
            if app.isHidden { line += ", hidden" }
            return line + ", pid=\(app.pid)]"
        }
        return ToolResult(blocks: [.text(lines.joined(separator: "\n"))])
    }

    /// The app's state: its focused (else frontmost) window's tree with the
    /// menu bar, plus a screenshot of that window. The walk and the capture
    /// run in parallel; neither needs the other.
    func state(app query: String, screenshot: Bool = true) async throws -> ToolResult {
        let clock = ContinuousClock()
        let started = clock.now
        let app = try directory.resolve(query)
        monitor.watch(pid: app.pid)
        let appElement = sessions.appElement(pid: app.pid)
        let windows = directory.windows(pid: app.pid)
        let focused = appElement.element(kAXFocusedWindowAttribute) ?? appElement.element(kAXMainWindowAttribute)
            ?? appElement.elements(kAXWindowsAttribute).first
        let focusedID = focused?.windowID
        let window = windows.first(where: { $0.id == focusedID }) ?? windows.first(where: \.onScreen) ?? windows.first
        let menuBar = appElement.element(kAXMenuBarAttribute)
        let resolved = clock.now

        var geometry: ScreenshotGeometry?
        if let window {
            geometry = ScreenshotGeometry(windowFrame: window.frame,
                                          displayScale: WindowCapture.scale(at: CGPoint(x: window.frame.midX, y: window.frame.midY)),
                                          maxLongEdge: maxImageEdge)
        }
        async let shot: (Data, Double, Double)? = screenshot ? captureJPEG(window, geometry) : nil
        let walkStart = clock.now
        let walked = walker.walk(window: focused, menuBar: menuBar)
        let walkMs = ms(clock.now - walkStart)
        let image = try await shot

        let snapshot = AppSnapshot(app: app, window: window, windowElement: focused, elements: walked.elements,
                                   geometry: geometry, taken: clock.now)
        sessions.store(snapshot)

        var header = "Computer Use state (cmux)\n<app_state>\n"
        header += "App=\(app.path ?? app.name) (bundleID \(app.bundleID ?? "?"), pid \(app.pid))\n"
        if let window {
            header += "Window: \"\(window.title.isEmpty ? app.name : window.title)\", App: \(app.name)."
            if let geometry { header += " Screenshot: \(geometry.pixelWidth)x\(geometry.pixelHeight) px." }
            header += "\n"
        } else {
            header += "No window.\n"
        }
        var text = header + renderer.render(walked.elements)
        if walked.truncated { text += "(tree truncated at \(walker.limits.maxNodes) elements)\n" }
        text += "</app_state>"
        var result = ToolResult(blocks: [.text(text)])
        if let image { result.blocks.append(.jpeg(image.0)) }
        result.timings = ["resolve_ms": ms(resolved - started), "walk_ms": walkMs, "nodes": Double(walked.elements.count),
                          "capture_ms": image?.1 ?? 0, "encode_ms": image?.2 ?? 0, "state_ms": ms(clock.now - started)]
        return result
    }

    private func captureJPEG(_ window: WindowInfo?, _ geometry: ScreenshotGeometry?) async throws -> (Data, Double, Double)? {
        guard let window, let geometry else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        let captured = try await capture.capture(windowID: window.id, pixelWidth: geometry.pixelWidth,
                                                 pixelHeight: geometry.pixelHeight)
        let captureDone = clock.now
        let data = try encoder.encode(captured.image)
        return (data, ms(captureDone - start), ms(clock.now - captureDone))
    }

    // MARK: Act

    struct Target {
        let snapshot: AppSnapshot
        let element: SnapshotElement?
    }

    /// The snapshot an action resolves its element index against; taken now
    /// when the app has none yet (the first call to an app needs no priming call).
    func target(app query: String, index: Int?) async throws -> Target {
        let app = try directory.resolve(query)
        var snapshot = sessions.snapshot(pid: app.pid)
        if snapshot == nil {
            _ = try await state(app: query, screenshot: false)
            snapshot = sessions.snapshot(pid: app.pid)
        }
        guard let snapshot else { throw EngineError("could not read \(app.name)'s state") }
        guard let index else { return Target(snapshot: snapshot, element: nil) }
        guard snapshot.elements.indices.contains(index) else {
            throw EngineError("element_index \(index) is not in \(app.name)'s last state (0..<\(snapshot.elements.count)); call get_app_state again")
        }
        return Target(snapshot: snapshot, element: snapshot.elements[index])
    }

    /// Runs `act`, waits for the app to settle, and returns the new state.
    func acting(app query: String, pid: pid_t, _ note: String, act: () throws -> Void) async throws -> ToolResult {
        let clock = ContinuousClock()
        monitor.watch(pid: pid)
        let start = clock.now
        try act()
        let actMs = ms(clock.now - start)
        let (outcome, waited) = await monitor.settle(pid: pid, since: start, policy: settle)
        var result = try await state(app: query)
        result.blocks.insert(.text(note), at: 0)
        result.timings["act_ms"] = actMs
        result.timings["settle_ms"] = ms(waited)
        result.timings["settle_\(outcome.rawValue)"] = 1
        return result
    }

    func click(app: String, index: Int?, x: Double?, y: Double?, button: PointerButton, count: Int) async throws -> ToolResult {
        let target = try await self.target(app: app, index: index)
        let pid = target.snapshot.app.pid
        if let element = target.element {
            let info = element.info
            // A plain left click on a pressable element is AXPress: exact,
            // works on background windows, and moves no pointer.
            if button == .left, count == 1, info.actions.contains(kAXPressAction) {
                return try await acting(app: app, pid: pid, "Clicked element \(index ?? -1).") {
                    let error = element.element.perform(kAXPressAction)
                    if error != .success { throw EngineError("AXPress failed on element \(index ?? -1) (\(error.rawValue))") }
                }
            }
            if button == .right, info.actions.contains(kAXShowMenuAction) {
                return try await acting(app: app, pid: pid, "Opened the menu of element \(index ?? -1).") {
                    element.element.perform(kAXShowMenuAction)
                }
            }
            guard let frame = info.frame, frame.width > 0, frame.height > 0 else {
                throw EngineError("element \(index ?? -1) has no frame to click")
            }
            let point = CGPoint(x: frame.midX, y: frame.midY)
            return try await acting(app: app, pid: pid, "Clicked element \(index ?? -1).") {
                input.click(at: point, pid: pid, windowNumber: target.snapshot.window?.id, button: button, count: count)
            }
        }
        guard let x, let y, let geometry = target.snapshot.geometry else {
            throw EngineError("click needs element_index, or x and y in the last screenshot's pixels")
        }
        let point = geometry.globalPoint(x: x, y: y)
        return try await acting(app: app, pid: pid, "Clicked at (\(Int(x)), \(Int(y))).") {
            input.click(at: point, pid: pid, windowNumber: target.snapshot.window?.id, button: button, count: count)
        }
    }

    func pressKey(app: String, key: String) async throws -> ToolResult {
        let spec = try KeySpec(parsing: key)
        let target = try await self.target(app: app, index: nil)
        let pid = target.snapshot.app.pid
        return try await acting(app: app, pid: pid, "Pressed \(key).") { input.key(spec, pid: pid) }
    }

    func typeText(app: String, text: String) async throws -> ToolResult {
        let target = try await self.target(app: app, index: nil)
        let pid = target.snapshot.app.pid
        return try await acting(app: app, pid: pid, "Typed \(text.count) characters.") { input.type(text, pid: pid) }
    }

    func setValue(app: String, index: Int, value: String) async throws -> ToolResult {
        let target = try await self.target(app: app, index: index)
        guard let element = target.element else { throw EngineError("set_value needs element_index") }
        return try await acting(app: app, pid: target.snapshot.app.pid, "Set the value of element \(index).") {
            let error = element.element.set(kAXValueAttribute, value as CFString)
            if error != .success { throw EngineError("element \(index) refused the value (\(error.rawValue))") }
        }
    }

    func selectText(app: String, index: Int, text: String) async throws -> ToolResult {
        let target = try await self.target(app: app, index: index)
        guard let element = target.element else { throw EngineError("select_text needs element_index") }
        let whole = element.element.string(kAXValueAttribute) ?? ""
        guard let range = whole.range(of: text) else { throw EngineError("\"\(text)\" is not in element \(index)'s text") }
        let location = whole.utf16.distance(from: whole.utf16.startIndex, to: range.lowerBound)
        var cfRange = CFRange(location: location, length: text.utf16.count)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { throw EngineError("could not make the range") }
        return try await acting(app: app, pid: target.snapshot.app.pid, "Selected \"\(text)\" in element \(index).") {
            element.element.set(kAXSelectedTextRangeAttribute, value)
        }
    }

    func secondaryAction(app: String, index: Int, action: String) async throws -> ToolResult {
        let target = try await self.target(app: app, index: index)
        guard let element = target.element else { throw EngineError("perform_secondary_action needs element_index") }
        guard let ax = TreeRenderer.axAction(named: action, in: element.info) else {
            let offered = element.info.actions.compactMap(TreeRenderer.secondaryName)
            throw EngineError("element \(index) has no action \"\(action)\" (it offers: \(offered.joined(separator: ", ")))")
        }
        return try await acting(app: app, pid: target.snapshot.app.pid, "Performed \(action) on element \(index).") {
            element.element.perform(ax)
        }
    }

    func scroll(app: String, index: Int?, direction: String, pages: Double) async throws -> ToolResult {
        let target = try await self.target(app: app, index: index)
        let pid = target.snapshot.app.pid
        let frame = target.element?.info.frame ?? target.snapshot.window?.frame
        guard let frame else { throw EngineError("nothing to scroll in \(target.snapshot.app.name)") }
        let distance = Int32((Double(direction == "left" || direction == "right" ? frame.width : frame.height) * 0.8 * pages).rounded())
        let (dx, dy): (Int32, Int32) = switch direction {
        case "up": (0, distance)
        case "down": (0, -distance)
        case "left": (distance, 0)
        case "right": (-distance, 0)
        default: throw EngineError("direction must be up, down, left or right")
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        return try await acting(app: app, pid: pid, "Scrolled \(direction).") {
            input.scroll(at: point, dx: dx, dy: dy, pid: pid, windowNumber: target.snapshot.window?.id)
        }
    }

    func drag(app: String, from: (Double, Double), to: (Double, Double)) async throws -> ToolResult {
        let target = try await self.target(app: app, index: nil)
        guard let geometry = target.snapshot.geometry else { throw EngineError("drag needs a window screenshot first") }
        let pid = target.snapshot.app.pid
        let start = geometry.globalPoint(x: from.0, y: from.1)
        let end = geometry.globalPoint(x: to.0, y: to.1)
        return try await acting(app: app, pid: pid, "Dragged.") {
            input.drag(from: start, to: end, pid: pid, windowNumber: target.snapshot.window?.id)
        }
    }
}

func ms(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return (Double(seconds) * 1000 + Double(attoseconds) / 1e15).rounded(toPlaces: 2)
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
