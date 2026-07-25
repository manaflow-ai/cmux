import ApplicationServices
import Foundation

func attribute(_ name: CFString, of element: AXUIElement) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
        return ""
    }
    return String(describing: value!)
}

func children(of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success,
        let children = value as? [AXUIElement]
    else {
        return []
    }
    return children
}

func dump(_ element: AXUIElement, depth: Int, maximumDepth: Int) {
    let role = attribute(kAXRoleAttribute as CFString, of: element)
    let title = attribute(kAXTitleAttribute as CFString, of: element)
    let description = attribute(kAXDescriptionAttribute as CFString, of: element)
    let enabled = attribute(kAXEnabledAttribute as CFString, of: element)
    print(
        "\(String(repeating: "  ", count: depth))\(role) title=\(title) description=\(description) enabled=\(enabled)"
    )
    guard depth < maximumDepth else {
        return
    }
    for child in children(of: element) {
        dump(child, depth: depth + 1, maximumDepth: maximumDepth)
    }
}

let application = AXUIElementCreateApplication(4_124)
for child in children(of: application) {
    if attribute(kAXRoleAttribute as CFString, of: child) == "AXMenuBar" {
        dump(child, depth: 0, maximumDepth: 4)
    }
}
