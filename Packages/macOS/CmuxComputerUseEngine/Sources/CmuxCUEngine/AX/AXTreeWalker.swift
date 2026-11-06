// SPDX-License-Identifier: GPL-3.0-or-later
@preconcurrency import ApplicationServices
import Foundation

/// What one node of a snapshot says about itself, read in one batched
/// accessibility round trip (`AXUIElementCopyMultipleAttributeValues`)
/// instead of one IPC per attribute.
struct AXNodeInfo: Sendable, Equatable {
    var role: String?
    var subrole: String?
    var roleDescription: String?
    var title: String?
    var label: String?
    var value: String?
    var identifier: String?
    var help: String?
    var enabled = true
    var focused = false
    var selected = false
    var valueSettable = false
    var frame: CGRect?
    var actions: [String] = []
    var depth = 0
}

/// One element of a snapshot: what it says and the live reference actions use.
struct SnapshotElement: @unchecked Sendable {
    let info: AXNodeInfo
    let element: AXElement
}

struct AXTreeLimits: Sendable {
    var maxNodes = 1500
    var maxDepth = 40
    var menuBarDepth = 1
}

/// Depth-first walk of one window plus the app's menu bar. Each node costs
/// two round trips to the target app: the batched attribute read and its
/// action names (needed to tell a press from a pointer click).
struct AXTreeWalker: Sendable {
    static let attributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute, kAXHelpAttribute,
        kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute, kAXChildrenAttribute,
        kAXPositionAttribute, kAXSizeAttribute,
    ]
    /// Roles whose value an agent may set (only these pay the settable probe).
    static let editableRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXSliderRole, "AXSearchField",
    ]
    let limits: AXTreeLimits

    init(limits: AXTreeLimits = AXTreeLimits()) { self.limits = limits }

    func walk(window: AXElement?, menuBar: AXElement?) -> (elements: [SnapshotElement], truncated: Bool) {
        var out: [SnapshotElement] = []
        out.reserveCapacity(256)
        var truncated = false
        // An explicit stack keeps preorder without recursion depth limits.
        var stack: [(AXElement, Int, Int)] = [] // element, depth, depth cap
        if let menuBar { stack.append((menuBar, 0, limits.menuBarDepth)) }
        if let window { stack.append((window, 0, limits.maxDepth)) }
        while let item = stack.popLast() {
            let (element, depth, cap) = item
            if out.count >= limits.maxNodes {
                truncated = true
                break
            }
            let read = Self.read(element)
            var info = read.0
            let children = read.1
            info.depth = depth
            out.append(SnapshotElement(info: info, element: element))
            guard depth < cap else {
                if !children.isEmpty { truncated = truncated || cap == limits.maxDepth }
                continue
            }
            for child in children.reversed() { stack.append((child, depth + 1, cap)) }
        }
        return (out, truncated)
    }

    static func read(_ element: AXElement) -> (AXNodeInfo, [AXElement]) {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element.raw, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        var info = AXNodeInfo()
        var children: [AXElement] = []
        guard error == .success, let array = values as? [CFTypeRef], array.count == attributes.count else {
            return (info, children)
        }
        func present(_ index: Int) -> CFTypeRef? {
            let value = array[index]
            if CFGetTypeID(value) == AXValueGetTypeID(),
               AXValueGetType(unsafeBitCast(value, to: AXValue.self)) == .axError { return nil }
            return value
        }
        info.role = present(0) as? String
        info.subrole = present(1) as? String
        info.roleDescription = present(2) as? String
        info.title = present(3) as? String
        info.label = present(4) as? String
        info.value = renderValue(present(5))
        info.identifier = present(6) as? String
        info.help = present(7) as? String
        info.enabled = (present(8) as? Bool) ?? true
        info.focused = (present(9) as? Bool) ?? false
        info.selected = (present(10) as? Bool) ?? false
        if let kids = present(11) as? [AXUIElement] { children = kids.map(AXElement.init) }
        if let origin = point(present(12)), let extent = size(present(13)) {
            info.frame = CGRect(origin: origin, size: extent)
        }
        info.actions = element.actionNames
        if let role = info.role, editableRoles.contains(role) {
            info.valueSettable = element.isSettable(kAXValueAttribute)
        }
        return (info, children)
    }

    static func renderValue(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return (value as? Bool) == true ? "1" : "0" }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
