import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func jsonOut(_ object: Any) -> Never {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
    exit(0)
}
func fail(_ code: String, _ message: String, details: [String: Any] = [:]) -> Never {
    var output: [String: Any] = ["ok": false, "code": code, "error": message]
    if !details.isEmpty { output["details"] = details }
    jsonOut(output)
}
func fail(_ message: String) -> Never { fail("provider.operationFailed", message) }
let maxAXStringCharacters = 512
let maxTreeCharacters = 60_000
func boundedString(_ value: String, limit: Int = maxAXStringCharacters) -> String {
    if value.count <= limit { return value }
    return String(value.prefix(limit)) + "…"
}
func stringAttr(_ element: AXUIElement, _ attr: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return "" }
    if let string = value as? String { return boundedString(string) }
    if let number = value as? NSNumber { return boundedString(number.stringValue) }
    return ""
}

func childrenAttr(_ element: AXUIElement, _ attr: String = kAXChildrenAttribute as String) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
}

func actionsFor(_ element: AXUIElement) -> [String] {
    var value: CFArray?
    guard AXUIElementCopyActionNames(element, &value) == .success else { return [] }
    return value as? [String] ?? []
}

func pointAttr(_ element: AXUIElement, _ attr: String) -> CGPoint? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = value as! AXValue
    var point = CGPoint.zero
    guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
    return point
}

func sizeAttr(_ element: AXUIElement, _ attr: String) -> CGSize? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = value as! AXValue
    var size = CGSize.zero
    guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
    return size
}

func boundsFor(_ element: AXUIElement) -> [String: Double]? {
    guard let point = pointAttr(element, kAXPositionAttribute as String),
          let size = sizeAttr(element, kAXSizeAttribute as String) else { return nil }
    return [
        "x": Double(point.x),
        "y": Double(point.y),
        "width": Double(size.width),
        "height": Double(size.height),
    ]
}

func intAttr(_ element: AXUIElement, _ attr: String) -> Int? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) }
    return nil
}

func windowNumberFor(_ element: AXUIElement) -> Int? {
    intAttr(element, "AXWindowNumber")
}

func frameText(_ bounds: [String: Double]?) -> String {
    guard let bounds else { return "" }
    let x = Int(bounds["x"] ?? 0)
    let y = Int(bounds["y"] ?? 0)
    let width = Int(bounds["width"] ?? 0)
    let height = Int(bounds["height"] ?? 0)
    return " frame={x:\(x),y:\(y),w:\(width),h:\(height)}"
}

func clean(_ value: String) -> String {
    boundedString(value).replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func appInfo(_ app: NSRunningApplication) -> [String: Any] {
    [
        "name": app.localizedName ?? "",
        "bundleIdentifier": app.bundleIdentifier ?? "",
        "pid": Int(app.processIdentifier),
    ]
}

func singleResolvedApp(_ apps: [NSRunningApplication], query: String) -> NSRunningApplication? {
    if apps.count > 1 {
        fail("provider.appAmbiguous", "ambiguous app match: \(query)", details: ["app": query])
    }
    return apps.first
}

func resolveApp(_ query: String, targetPid: pid_t?, targetBundleIdentifier: String?) -> NSRunningApplication? {
    if let targetPid {
        guard let app = NSRunningApplication(processIdentifier: targetPid) else { return nil }
        if let targetBundleIdentifier, !targetBundleIdentifier.isEmpty,
           app.bundleIdentifier != targetBundleIdentifier {
            fail("provider.appIdentityChanged", "target app identity changed for pid \(targetPid)", details: ["pid": Int(targetPid)])
        }
        return app
    }

    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    let lower = trimmed.lowercased()
    let exact = apps.filter { $0.bundleIdentifier == trimmed || $0.localizedName == trimmed }
    if !exact.isEmpty {
        return singleResolvedApp(exact, query: trimmed)
    }
    let caseInsensitiveExact = apps.filter {
        ($0.bundleIdentifier ?? "").lowercased() == lower ||
        ($0.localizedName ?? "").lowercased() == lower
    }
    if !caseInsensitiveExact.isEmpty {
        return singleResolvedApp(caseInsensitiveExact, query: trimmed)
    }
    return nil
}

func visibleWindowEntries(pid: pid_t? = nil) -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.filter { entry in
        let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1
        let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        if let pid {
            return layer == 0 && ownerPID == Int(pid)
        }
        return layer == 0
    }
}

func windowEntryBounds(_ entry: [String: Any]) -> [String: Double]? {
    guard let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return [
        "x": Double((bounds["X"] as? NSNumber)?.doubleValue ?? 0),
        "y": Double((bounds["Y"] as? NSNumber)?.doubleValue ?? 0),
        "width": Double((bounds["Width"] as? NSNumber)?.doubleValue ?? 0),
        "height": Double((bounds["Height"] as? NSNumber)?.doubleValue ?? 0),
    ]
}

func windowInfo(_ entry: [String: Any]) -> [String: Any] {
    var output: [String: Any] = [
        "id": (entry[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1,
        "title": entry[kCGWindowName as String] ?? "",
        "app": entry[kCGWindowOwnerName as String] ?? "",
        "pid": (entry[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1,
    ]
    if let bounds = windowEntryBounds(entry) {
        output["bounds"] = bounds
    }
    return output
}

func windowInfoFor(pid: pid_t, windowId: Int?) -> [String: Any]? {
    for entry in visibleWindowEntries(pid: pid) {
        let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1
        if let windowId, number != windowId { continue }
        return windowInfo(entry)
    }
    return nil
}

func listWindows(match: String?) -> [[String: Any]] {
    let needle = (match ?? "").lowercased()
    var windows: [[String: Any]] = []
    for entry in visibleWindowEntries() {
        let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        let app = entry[kCGWindowOwnerName as String] ?? ""
        let title = entry[kCGWindowName as String] ?? ""
        if !needle.isEmpty &&
           !String(describing: app).lowercased().contains(needle) &&
           !String(describing: title).lowercased().contains(needle) {
            continue
        }
        var window: [String: Any] = [
            "id": entry[kCGWindowNumber as String] ?? 0,
            "app": app,
            "title": title,
            "pid": entry[kCGWindowOwnerPID as String] ?? 0,
            "layer": layer,
        ]
        if let bounds = entry[kCGWindowBounds as String] as? [String: Any] {
            window["bounds"] = bounds
        }
        windows.append(window)
    }
    return windows
}

func resolvedWindowIdFor(_ window: AXUIElement, pid: pid_t) -> Int? {
    if let windowNumber = windowNumberFor(window) { return windowNumber }
    guard let axBounds = boundsFor(window) else { return nil }
    let matches = visibleWindowEntries(pid: pid).compactMap { entry -> Int? in
        guard let bounds = windowEntryBounds(entry),
              boundsNearlyEqual(bounds, axBounds) else {
            return nil
        }
        return (entry[kCGWindowNumber as String] as? NSNumber)?.intValue
    }
    return matches.count == 1 ? matches[0] : nil
}

func appRoot(_ app: NSRunningApplication, windowIndex: Int?, windowId: Int?) -> (AXUIElement, String, Int?, Int?) {
    let root = AXUIElementCreateApplication(app.processIdentifier)
    let windows = childrenAttr(root, kAXWindowsAttribute as String)
        .filter { stringAttr($0, kAXRoleAttribute as String) != "AXHelpTag" }
    if !windows.isEmpty {
        if let windowId {
            for (index, window) in windows.enumerated() {
                if resolvedWindowIdFor(window, pid: app.processIdentifier) == windowId {
                    return (window, "window", index, windowId)
                }
            }
            fail("provider.windowChanged", "window no longer exists: \(windowId)", details: ["windowId": windowId])
        }
        let index = min(max(windowIndex ?? 0, 0), windows.count - 1)
        let window = windows[index]
        return (window, "window", index, resolvedWindowIdFor(window, pid: app.processIdentifier))
    }
    if let windowId {
        fail("provider.windowChanged", "window no longer exists: \(windowId)", details: ["windowId": windowId])
    }
    return (root, "app", nil, nil)
}

func waitForFrontmost(_ app: NSRunningApplication, timeoutMS: Int) -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
    repeat {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            return true
        }
        usleep(20_000)
    } while Date() < deadline
    return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
}

func requestActivation(_ app: NSRunningApplication) {
    _ = app.activate(options: [.activateAllWindows])
    if waitForFrontmost(app, timeoutMS: 350) { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty {
        process.arguments = ["-b", bundleIdentifier]
    } else if let bundleURL = app.bundleURL {
        process.arguments = [bundleURL.path]
    } else {
        return
    }
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return
    }
}

func ensureFrontmostForInput(_ app: NSRunningApplication) {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
    requestActivation(app)
    guard waitForFrontmost(app, timeoutMS: 1200) else {
        fail("provider.focusFailed", "target app did not become frontmost for input")
    }
}

func ensureFocusedWindow(_ app: NSRunningApplication, _ window: AXUIElement, windowId: Int?) {
    guard let windowId else { return }
    guard resolvedWindowIdFor(window, pid: app.processIdentifier) == windowId else {
        fail("provider.windowChanged", "window no longer exists: \(windowId)", details: ["windowId": windowId])
    }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
    usleep(50_000)
    guard waitForFrontmost(app, timeoutMS: 1200) else {
        fail("provider.focusFailed", "target app did not become frontmost for input")
    }
    var focusedValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
          let focusedValue,
          CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
        fail("provider.focusFailed", "target window did not become focused for input")
    }
    let focusedWindow = focusedValue as! AXUIElement
    guard resolvedWindowIdFor(focusedWindow, pid: app.processIdentifier) == windowId else {
        fail("provider.focusFailed", "target window did not become focused for input")
    }
}

func doubleInput(_ key: String) -> Double? {
    (inputObject[key] as? NSNumber)?.doubleValue
}

func boundsObject(_ value: Any?) -> [String: Double]? {
    guard let object = value as? [String: Any] else { return nil }
    let x = (object["x"] as? NSNumber)?.doubleValue
    let y = (object["y"] as? NSNumber)?.doubleValue
    let width = (object["width"] as? NSNumber)?.doubleValue
    let height = (object["height"] as? NSNumber)?.doubleValue
    guard let x, let y, let width, let height else { return nil }
    return ["x": x, "y": y, "width": width, "height": height]
}

func boundsNearlyEqual(_ lhs: [String: Double], _ rhs: [String: Double]) -> Bool {
    for key in ["x", "y", "width", "height"] {
        guard let a = lhs[key], let b = rhs[key], abs(a - b) <= 1.0 else { return false }
    }
    return true
}

func currentWindowBounds(pid: pid_t, windowId: Int?, expected: [String: Double]?) -> [String: Double] {
    guard let windowId else { fail("provider.windowIdentityRequired", "stable window identity is required for coordinate input") }
    guard let window = windowInfoFor(pid: pid, windowId: windowId),
          let bounds = window["bounds"] as? [String: Double] else {
        fail("provider.windowChanged", "window no longer exists: \(windowId)", details: ["windowId": windowId])
    }
    if let expected, !boundsNearlyEqual(bounds, expected) {
        fail("provider.windowBoundsChanged", "window bounds changed since the screenshot; re-run computer_state")
    }
    return bounds
}

func pointFromSnapshotPixels(xKey: String, yKey: String, bounds: [String: Double]) -> CGPoint {
    guard let pixelX = doubleInput(xKey),
          let pixelY = doubleInput(yKey),
          let imageWidth = doubleInput("imageWidth"),
          let imageHeight = doubleInput("imageHeight"),
          imageWidth > 0,
          imageHeight > 0 else {
        fail("provider.coordinateGeometryMissing", "coordinate input is missing snapshot geometry")
    }
    return CGPoint(
        x: (bounds["x"] ?? 0) + (pixelX / imageWidth) * (bounds["width"] ?? 0),
        y: (bounds["y"] ?? 0) + (pixelY / imageHeight) * (bounds["height"] ?? 0)
    )
}

func elementAtPath(root: AXUIElement, path: [Int]) -> AXUIElement? {
    var current = root
    for index in path {
        let children = childrenAttr(current)
        if index < 0 || index >= children.count { return nil }
        current = children[index]
    }
    return current
}

func centerOf(_ element: AXUIElement) -> CGPoint? {
    guard let bounds = boundsFor(element) else { return nil }
    return CGPoint(
        x: (bounds["x"] ?? 0) + (bounds["width"] ?? 0) / 2,
        y: (bounds["y"] ?? 0) + (bounds["height"] ?? 0) / 2
    )
}

func postMouse(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func glidePointer(to target: CGPoint, durationMs: Int = 180) {
    guard let start = CGEvent(source: nil)?.location else {
        postMouse(.mouseMoved, target)
        return
    }

    let dx = target.x - start.x
    let dy = target.y - start.y
    if hypot(dx, dy) < 2.0 {
        postMouse(.mouseMoved, target)
        return
    }

    let intervalUs: useconds_t = 12_000
    let clampedDurationMs = max(1, durationMs)
    let steps = max(1, Int(ceil(Double(clampedDurationMs) / 12.0)))
    for step in 1...steps {
        let linear = CGFloat(step) / CGFloat(steps)
        let eased = linear * linear * (3.0 - 2.0 * linear)
        let point = CGPoint(x: start.x + dx * eased, y: start.y + dy * eased)
        postMouse(.mouseMoved, point)
        if step < steps {
            usleep(intervalUs)
        }
    }
    postMouse(.mouseMoved, target)
}

func clickAt(_ point: CGPoint) {
    postMouse(.mouseMoved, point)
    usleep(30_000)
    postMouse(.leftMouseDown, point)
    usleep(40_000)
    postMouse(.leftMouseUp, point)
}

func typeText(_ text: String) {
    for character in text {
        let utf16 = Array(String(character).utf16)
        utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
            up?.post(tap: .cghidEventTap)
        }
        usleep(5_000)
    }
}

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
    "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
    "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
    "`": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
    "home": 115, "pageup": 116, "end": 119, "pagedown": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]

func pressKey(_ key: String) {
    let parts = key.lowercased().split(separator: "+").map(String.init)
    guard let rawKey = parts.last, !rawKey.isEmpty else {
        fail("provider.unsupportedKey", "unsupported key: \(key)", details: ["key": key])
    }
    var flags = CGEventFlags()
    for part in parts.dropLast() {
        switch part {
        case "cmd", "command", "meta": flags.insert(.maskCommand)
        case "ctrl", "control": flags.insert(.maskControl)
        case "alt", "option": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        default: fail("provider.unsupportedKey", "unsupported key modifier: \(part)", details: ["key": part])
        }
    }
    if parts.count == 1 && rawKey.count == 1 && keyCodes[rawKey] == nil {
        typeText(rawKey)
        return
    }
    guard let code = keyCodes[rawKey] else {
        fail("provider.unsupportedKey", "unsupported key: \(key)", details: ["key": key])
    }
    let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
}

func pathInput() -> [Int] {
    (inputObject["path"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
}
