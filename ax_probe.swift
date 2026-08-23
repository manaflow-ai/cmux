import Cocoa
import ApplicationServices

let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)

func attribute(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key, &value) == .success else { return nil }
    return value
}

func text(_ element: AXUIElement, _ key: CFString) -> String {
    (attribute(element, key) as? String) ?? ""
}

func walk(_ element: AXUIElement, depth: Int) {
    let role = text(element, kAXRoleAttribute as CFString)
    let identifier = text(element, kAXIdentifierAttribute as CFString)
    let title = text(element, kAXTitleAttribute as CFString)
    let description = text(element, kAXDescriptionAttribute as CFString)
    if !identifier.isEmpty || role == "AXButton" || role == "AXMenuButton" || role == "AXWindow" {
        let position = attribute(element, kAXPositionAttribute as CFString).map { "\($0)" } ?? ""
        let size = attribute(element, kAXSizeAttribute as CFString).map { "\($0)" } ?? ""
        print(String(repeating: " ", count: depth * 2) + "role=\(role) id=\(identifier) title=\(title) desc=\(description) pos=\(position) size=\(size)")
    }
    guard depth < 12, let rawChildren = attribute(element, kAXChildrenAttribute as CFString) else { return }
    let children = rawChildren as! [AXUIElement]
    for child in children { walk(child, depth: depth + 1) }
}

if CommandLine.arguments.dropFirst(2).contains("move") {
    if let rawWindows = attribute(app, kAXWindowsAttribute as CFString) {
        let windows = rawWindows as! [AXUIElement]
        if let window = windows.first {
            var position = CGPoint(x: 0, y: 30)
            var size = CGSize(width: 2560, height: 1410)
            if let positionValue = AXValueCreate(.cgPoint, &position) {
                print("move position", AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue).rawValue)
            }
            if let sizeValue = AXValueCreate(.cgSize, &size) {
                print("move size", AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue).rawValue)
            }
        }
    }
}

walk(app, depth: 0)
