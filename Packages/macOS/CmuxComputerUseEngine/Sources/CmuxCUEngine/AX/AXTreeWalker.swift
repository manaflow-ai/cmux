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

    /// Reads at most this many nodes of one level at a time. The target app
    /// answers on its own main thread, so this only overlaps round-trip
    /// latency; more threads stop helping.
    static let readWidth = 4

    /// Breadth-first, one level at a time with the level's nodes read in
    /// parallel, then emitted in preorder (window first, then menu bar), so
    /// indexes read top to bottom like the screen.
    func walk(window: AXElement?, menuBar: AXElement?) -> (elements: [SnapshotElement], truncated: Bool) {
        final class Node: @unchecked Sendable {
            let element: AXElement
            let depth: Int
            let cap: Int
            var info = AXNodeInfo()
            var children: [Node] = []
            var rawChildren: [AXElement] = []
            var wasRead = false
            init(_ element: AXElement, depth: Int, cap: Int) {
                self.element = element
                self.depth = depth
                self.cap = cap
            }
        }
        var roots: [Node] = []
        if let window { roots.append(Node(window, depth: 0, cap: limits.maxDepth)) }
        if let menuBar { roots.append(Node(menuBar, depth: 0, cap: limits.menuBarDepth)) }
        var level = roots
        var count = 0
        var truncated = false
        while !level.isEmpty {
            let budget = limits.maxNodes - count
            if level.count > budget {
                level = Array(level.prefix(max(0, budget)))
                truncated = true
            }
            let batch = level
            DispatchQueue.concurrentPerform(iterations: min(Self.readWidth, batch.count)) { worker in
                var index = worker
                while index < batch.count {
                    let read = Self.read(batch[index].element)
                    batch[index].info = read.0
                    batch[index].info.depth = batch[index].depth
                    batch[index].rawChildren = read.1
                    batch[index].wasRead = true
                    index += Self.readWidth
                }
            }
            count += batch.count
            var next: [Node] = []
            for node in batch {
                guard node.depth < node.cap else {
                    if !node.rawChildren.isEmpty, node.cap == limits.maxDepth { truncated = true }
                    continue
                }
                node.children = node.rawChildren.map { Node($0, depth: node.depth + 1, cap: node.cap) }
                next.append(contentsOf: node.children)
            }
            if count >= limits.maxNodes, !next.isEmpty {
                truncated = true
                break
            }
            level = next
        }
        var out: [SnapshotElement] = []
        out.reserveCapacity(count)
        var stack = Array(roots.reversed())
        while let node = stack.popLast() {
            // A node of the last, cut level was never read: leave it out.
            guard node.wasRead else { continue }
            out.append(SnapshotElement(info: node.info, element: node.element))
            stack.append(contentsOf: node.children.reversed())
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
