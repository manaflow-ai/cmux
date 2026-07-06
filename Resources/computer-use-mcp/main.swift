import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let inputData: Data
let payloadArgument = CommandLine.arguments.dropFirst().last { $0 != "--" }
if let payloadArgument, let data = Data(base64Encoded: payloadArgument) {
    inputData = data
} else {
    inputData = Data()
}
let inputObject = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] ?? [:]
let op = inputObject["op"] as? String ?? ""

if op == "list_apps" {
    let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .map { appInfo($0) }
    jsonOut(["ok": true, "apps": apps])
}

if op == "list_windows" {
    jsonOut(["ok": true, "windows": listWindows(match: inputObject["match"] as? String)])
}

let appQuery = inputObject["app"] as? String ?? ""
let targetPid = (inputObject["targetPid"] as? NSNumber).map { pid_t($0.intValue) }
let targetBundleIdentifier = inputObject["targetBundleIdentifier"] as? String
guard let app = resolveApp(appQuery, targetPid: targetPid, targetBundleIdentifier: targetBundleIdentifier) else {
    fail("app not found: \(appQuery)")
}

if op == "state" {
    guard AXIsProcessTrusted() else {
        fail("Accessibility permission is required for cmux computer use.")
    }
    let (root, rootKind, windowIndex, windowId) = appRoot(app, windowIndex: nil, windowId: nil)
    let maxNodes = min(max((inputObject["maxNodes"] as? NSNumber)?.intValue ?? 1200, 1), 5000)
    let maxDepth = min(max((inputObject["maxDepth"] as? NSNumber)?.intValue ?? 10, 1), 20)
    var nextIndex = 0
    var lines: [String] = []
    var elements: [[String: Any]] = []
    var treeCharacters = 0

    func visit(_ element: AXUIElement, path: [Int], depth: Int) {
        if nextIndex >= maxNodes { return }
        let index = nextIndex
        nextIndex += 1
        let role = stringAttr(element, kAXRoleAttribute as String)
        let subrole = stringAttr(element, kAXSubroleAttribute as String)
        let title = stringAttr(element, kAXTitleAttribute as String)
        let value = stringAttr(element, kAXValueAttribute as String)
        let description = stringAttr(element, kAXDescriptionAttribute as String)
        let help = stringAttr(element, kAXHelpAttribute as String)
        let actions = actionsFor(element)
        let bounds = boundsFor(element)
        var elementInfo: [String: Any] = [
            "index": index,
            "path": path,
            "actions": actions,
        ]
        if let bounds { elementInfo["bounds"] = bounds }
        elements.append(elementInfo)

        let indent = String(repeating: "  ", count: depth)
        var line = "\(indent)[\(index)] \(role.isEmpty ? "AXElement" : role)"
        if !subrole.isEmpty { line += " subrole=\"\(clean(subrole))\"" }
        if !title.isEmpty { line += " title=\"\(clean(title))\"" }
        if !value.isEmpty { line += " value=\"\(clean(value))\"" }
        if !description.isEmpty { line += " description=\"\(clean(description))\"" }
        if !help.isEmpty { line += " help=\"\(clean(help))\"" }
        line += frameText(bounds)
        if !actions.isEmpty { line += " actions=\(actions)" }
        if treeCharacters < maxTreeCharacters {
            let remaining = maxTreeCharacters - treeCharacters
            let clipped = line.count > remaining ? String(line.prefix(max(0, remaining))) + "…[truncated]" : line
            lines.append(clipped)
            treeCharacters += clipped.count + 1
        }

        if depth >= maxDepth { return }
        let children = childrenAttr(element)
        for (childIndex, child) in children.prefix(100).enumerated() {
            visit(child, path: path + [childIndex], depth: depth + 1)
        }
    }

    visit(root, path: [], depth: 0)
    var response: [String: Any] = [
        "ok": true,
        "tree": lines.joined(separator: "\n"),
        "elements": elements,
        "root": rootKind,
        "target": appInfo(app),
    ]
    if let windowIndex {
        response["windowIndex"] = windowIndex
    }
    if let windowId {
        response["windowId"] = windowId
    }
    if let windowId, let window = windowInfoFor(pid: app.processIdentifier, windowId: windowId) {
        response["window"] = window
    }
    jsonOut(response)
}

guard AXIsProcessTrusted() else {
    fail("Accessibility permission is required for cmux computer use.")
}
if op == "type_text" || op == "press_key" || op == "click_element" || op == "click_point" || op == "scroll" || op == "drag" {
    ensureFrontmostForInput(app)
} else {
    _ = app.activate()
}
let (root, rootKind, _, resolvedWindowId) = appRoot(
    app,
    windowIndex: (inputObject["windowIndex"] as? NSNumber)?.intValue,
    windowId: (inputObject["windowId"] as? NSNumber)?.intValue
)
ensureFocusedWindow(app, root, windowId: rootKind == "window" ? resolvedWindowId : nil)
let element = elementAtPath(root: root, path: pathInput())
let expectedWindowBounds = boundsObject(inputObject["expectedWindowBounds"])

switch op {
case "click_element":
    guard let element else { fail("element no longer exists") }
    let actions = actionsFor(element)
    if let point = centerOf(element) {
        postMouse(.mouseMoved, point)
        usleep(30_000)
    }
    if actions.contains(kAXPressAction as String),
       AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
        jsonOut(["ok": true, "message": "pressed"])
    }
    guard let point = centerOf(element) else { fail("element has no clickable frame") }
    clickAt(point)
    jsonOut(["ok": true, "message": "clicked"])
case "click_point":
    let bounds = currentWindowBounds(
        pid: app.processIdentifier,
        windowId: resolvedWindowId,
        expected: expectedWindowBounds
    )
    clickAt(pointFromSnapshotPixels(xKey: "pixelX", yKey: "pixelY", bounds: bounds))
    jsonOut(["ok": true, "message": "clicked"])
case "type_text":
    typeText(inputObject["text"] as? String ?? "")
    jsonOut(["ok": true, "message": "typed"])
case "press_key":
    pressKey(inputObject["key"] as? String ?? "")
    jsonOut(["ok": true, "message": "key sent"])
case "scroll":
    guard let element else { fail("element no longer exists") }
    guard let point = centerOf(element) else { fail("element has no scrollable frame") }
    postMouse(.mouseMoved, point)
    let direction = inputObject["direction"] as? String ?? "down"
    let pages = max(1, (inputObject["pages"] as? NSNumber)?.intValue ?? 1)
    let amount = Int32(8 * pages)
    let dy: Int32 = direction == "up" ? amount : (direction == "down" ? -amount : 0)
    let dx: Int32 = direction == "left" ? amount : (direction == "right" ? -amount : 0)
    CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
        .post(tap: .cghidEventTap)
    jsonOut(["ok": true, "message": "scrolled"])
case "drag":
    let bounds = currentWindowBounds(
        pid: app.processIdentifier,
        windowId: resolvedWindowId,
        expected: expectedWindowBounds
    )
    let start = pointFromSnapshotPixels(xKey: "fromPixelX", yKey: "fromPixelY", bounds: bounds)
    let end = pointFromSnapshotPixels(xKey: "toPixelX", yKey: "toPixelY", bounds: bounds)
    postMouse(.mouseMoved, start)
    usleep(30_000)
    postMouse(.leftMouseDown, start)
    for step in 1...12 {
        let t = CGFloat(step) / 12.0
        let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        postMouse(.leftMouseDragged, point)
        usleep(8_000)
    }
    postMouse(.leftMouseUp, end)
    jsonOut(["ok": true, "message": "dragged"])
case "action":
    guard let element else { fail("element no longer exists") }
    let action = inputObject["action"] as? String ?? ""
    if AXUIElementPerformAction(element, action as CFString) == .success {
        jsonOut(["ok": true, "message": "action sent"])
    }
    fail("action failed: \(action)")
default:
    fail("unknown operation: \(op)")
}
