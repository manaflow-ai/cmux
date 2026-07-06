import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let inputData: Data
let payloadArgument = CommandLine.arguments.dropFirst().last { $0 != "--" }
if let payloadArgument, let data = Data(base64Encoded: payloadArgument) {
    inputData = data
} else {
    inputData = FileHandle.standardInput.readDataToEndOfFile()
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
    fail("provider.appNotFound", "app not found: \(appQuery)", details: ["app": appQuery])
}

if op == "resolve_app" {
    jsonOut(["ok": true, "target": appInfo(app)])
}

func elementSnapshot(_ element: AXUIElement, path: [Int], index: Int? = nil) -> [String: Any] {
    let role = stringAttr(element, kAXRoleAttribute as String)
    let subrole = stringAttr(element, kAXSubroleAttribute as String)
    let title = stringAttr(element, kAXTitleAttribute as String)
    let value = stringAttr(element, kAXValueAttribute as String)
    let description = stringAttr(element, kAXDescriptionAttribute as String)
    let help = stringAttr(element, kAXHelpAttribute as String)
    let actions = actionsFor(element)
    let bounds = boundsFor(element)
    var snapshot: [String: Any] = [
        "path": path,
        "role": role,
        "subrole": subrole,
        "title": title,
        "value": value,
        "description": description,
        "help": help,
        "actions": actions,
    ]
    if let index { snapshot["index"] = index }
    if let bounds { snapshot["bounds"] = bounds }
    return snapshot
}

func elementMatchesSnapshot(_ element: AXUIElement, expected: [String: Any]) -> Bool {
    for (key, attr) in [
        ("role", kAXRoleAttribute as String),
        ("subrole", kAXSubroleAttribute as String),
        ("title", kAXTitleAttribute as String),
        ("value", kAXValueAttribute as String),
        ("description", kAXDescriptionAttribute as String),
        ("help", kAXHelpAttribute as String),
    ] {
        guard stringAttr(element, attr) == (expected[key] as? String ?? "") else { return false }
    }
    let expectedActions = Set((expected["actions"] as? [Any])?.compactMap { $0 as? String } ?? [])
    guard Set(actionsFor(element)) == expectedActions else { return false }
    if let expectedBounds = boundsObject(expected["bounds"]) {
        guard let currentBounds = boundsFor(element),
              boundsNearlyEqual(currentBounds, expectedBounds) else { return false }
    }
    return true
}

func elementForInput(root: AXUIElement, path: [Int], expected: [String: Any]?) -> AXUIElement {
    guard let element = elementAtPath(root: root, path: path) else {
        fail("provider.elementMissing", "element no longer exists")
    }
    guard let expected else {
        fail("provider.elementSnapshotRequired", "element action is missing a snapshot fingerprint")
    }
    if let expectedPath = (expected["path"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }),
       expectedPath != path {
        fail("provider.elementChanged", "element changed since the latest computer_state snapshot")
    }
    guard elementMatchesSnapshot(element, expected: expected) else {
        fail("provider.elementChanged", "element changed since the latest computer_state snapshot")
    }
    return element
}

if op == "state" {
    guard AXIsProcessTrusted() else {
        fail("provider.accessibilityRequired", "Accessibility permission is required for cmux computer use.")
    }
    let (root, rootKind, windowIndex, windowId) = appRoot(app, windowIndex: nil, windowId: nil)
    let maxNodes = min(max((inputObject["maxNodes"] as? NSNumber)?.intValue ?? 1200, 1), 5000)
    let maxDepth = min(max((inputObject["maxDepth"] as? NSNumber)?.intValue ?? 10, 1), 20)
    var nextIndex = 0
    var lines: [String] = []
    var elements: [[String: Any]] = []
    var treeCharacters = 0

    func visit(_ element: AXUIElement, path: [Int], depth: Int) {
        if nextIndex >= maxNodes || treeCharacters >= maxTreeCharacters { return }
        let index = nextIndex
        let role = stringAttr(element, kAXRoleAttribute as String)
        let subrole = stringAttr(element, kAXSubroleAttribute as String)
        let title = stringAttr(element, kAXTitleAttribute as String)
        let value = stringAttr(element, kAXValueAttribute as String)
        let description = stringAttr(element, kAXDescriptionAttribute as String)
        let help = stringAttr(element, kAXHelpAttribute as String)
        let actions = actionsFor(element)
        let bounds = boundsFor(element)

        let indent = String(repeating: "  ", count: depth)
        var line = "\(indent)[\(index)] \(role.isEmpty ? "AXElement" : role)"
        if !subrole.isEmpty { line += " subrole=\"\(clean(subrole))\"" }
        if !title.isEmpty { line += " title=\"\(clean(title))\"" }
        if !value.isEmpty { line += " value=\"\(clean(value))\"" }
        if !description.isEmpty { line += " description=\"\(clean(description))\"" }
        if !help.isEmpty { line += " help=\"\(clean(help))\"" }
        line += frameText(bounds)
        if !actions.isEmpty { line += " actions=\(actions)" }
        guard treeCharacters + line.count + 1 <= maxTreeCharacters else {
            if treeCharacters < maxTreeCharacters {
                let marker = "…[truncated AX tree]"
                lines.append(String(marker.prefix(maxTreeCharacters - treeCharacters)))
                treeCharacters = maxTreeCharacters
            }
            return
        }
        nextIndex += 1
        var elementInfo = elementSnapshot(element, path: path, index: index)
        if let bounds { elementInfo["bounds"] = bounds }
        elements.append(elementInfo)
        lines.append(line)
        treeCharacters += line.count + 1

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
    fail("provider.accessibilityRequired", "Accessibility permission is required for cmux computer use.")
}
let inputOperations: Set<String> = ["type_text", "press_key", "click_element", "click_point", "scroll", "drag", "action"]
guard inputOperations.contains(op) else {
    fail("provider.unknownOperation", "unknown operation: \(op)", details: ["operation": op])
}
let requestedWindowIndex = (inputObject["windowIndex"] as? NSNumber)?.intValue
let requestedWindowId = (inputObject["windowId"] as? NSNumber)?.intValue
let expectedWindowBounds = boundsObject(inputObject["expectedWindowBounds"])
let expectedElement = inputObject["expectedElement"] as? [String: Any]
let path = pathInput()
let (preflightRoot, _, _, preflightWindowId) = appRoot(
    app,
    windowIndex: requestedWindowIndex,
    windowId: requestedWindowId
)

switch op {
case "click_element", "scroll", "action":
    _ = elementForInput(root: preflightRoot, path: path, expected: expectedElement)
case "click_point":
    let bounds = currentWindowBounds(pid: app.processIdentifier, windowId: preflightWindowId, expected: expectedWindowBounds)
    _ = pointFromSnapshotPixels(xKey: "pixelX", yKey: "pixelY", bounds: bounds)
case "drag":
    let bounds = currentWindowBounds(pid: app.processIdentifier, windowId: preflightWindowId, expected: expectedWindowBounds)
    _ = pointFromSnapshotPixels(xKey: "fromPixelX", yKey: "fromPixelY", bounds: bounds)
    _ = pointFromSnapshotPixels(xKey: "toPixelX", yKey: "toPixelY", bounds: bounds)
default:
    break
}

ensureFrontmostForInput(app)
let (root, rootKind, _, resolvedWindowId) = appRoot(
    app,
    windowIndex: requestedWindowIndex,
    windowId: requestedWindowId
)
ensureFocusedWindow(app, root, windowId: rootKind == "window" ? resolvedWindowId : nil)
let inputElement = ["click_element", "scroll", "action"].contains(op)
    ? elementForInput(root: root, path: path, expected: expectedElement)
    : nil

switch op {
case "click_element":
    guard let element = inputElement else { fail("provider.elementMissing", "element no longer exists") }
    let actions = actionsFor(element)
    if let point = centerOf(element) {
        glidePointer(to: point)
    }
    if actions.contains(kAXPressAction as String),
       AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
        jsonOut(["ok": true, "message": "pressed"])
    }
    guard let point = centerOf(element) else { fail("provider.elementFrameMissing", "element has no clickable frame") }
    clickAt(point)
    jsonOut(["ok": true, "message": "clicked"])
case "click_point":
    let bounds = currentWindowBounds(
        pid: app.processIdentifier,
        windowId: resolvedWindowId,
        expected: expectedWindowBounds
    )
    let point = pointFromSnapshotPixels(xKey: "pixelX", yKey: "pixelY", bounds: bounds)
    glidePointer(to: point)
    clickAt(point)
    jsonOut(["ok": true, "message": "clicked"])
case "type_text":
    typeText(inputObject["text"] as? String ?? "")
    jsonOut(["ok": true, "message": "typed"])
case "press_key":
    pressKey(inputObject["key"] as? String ?? "")
    jsonOut(["ok": true, "message": "key sent"])
case "scroll":
    guard let element = inputElement else { fail("provider.elementMissing", "element no longer exists") }
    guard let point = centerOf(element) else { fail("provider.elementFrameMissing", "element has no scrollable frame") }
    glidePointer(to: point)
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
    glidePointer(to: start)
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
    guard let element = inputElement else { fail("provider.elementMissing", "element no longer exists") }
    let action = inputObject["action"] as? String ?? ""
    if let point = centerOf(element) {
        glidePointer(to: point)
    }
    if AXUIElementPerformAction(element, action as CFString) == .success {
        jsonOut(["ok": true, "message": "action sent"])
    }
    fail("provider.actionFailed", "action failed: \(action)", details: ["action": action])
default:
    fail("provider.unknownOperation", "unknown operation: \(op)", details: ["operation": op])
}
