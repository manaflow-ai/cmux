import AppKit

/// One element of the in-process accessibility tree, as an accessibility client (VoiceOver, a
/// computer-use agent reading AXUIElement) reaches it.
struct AccessibilityNode {
    let role: NSAccessibility.Role
    let label: String
    let identifier: String
    /// Roles from the root down to this element, for failure messages.
    let path: String
    /// The element itself (a view, or a control's cell), for identity checks.
    let element: NSObject
}

/// Walks the accessibility tree under a view the way a client sees it (elements only, hidden
/// views skipped, a control's cell carrying the control's name) and lists every control an agent could not
/// find or name: a pressable element without a label or a stable identifier, or an image that is
/// exposed without a description (decorative images must not be elements).
struct AccessibilityAudit {
    /// Roles an agent presses, toggles or drags: each needs a label and an identifier.
    let actionableRoles: Set<NSAccessibility.Role> = [
        .button, .menuButton, .popUpButton, .radioButton, .checkBox, .disclosureTriangle, .splitter, .slider,
    ]
    /// A guard against a cycle in a broken tree.
    let maxNodes = 5000

    /// Every element under `root` (the root included when it is an element).
    func nodes(under root: Any) -> [AccessibilityNode] {
        var out: [AccessibilityNode] = []
        var seen = Set<ObjectIdentifier>()
        walk(root, path: "", into: &out, seen: &seen)
        return out
    }

    /// One line per control an agent cannot use.
    func violations(under root: Any) -> [String] {
        nodes(under: root).compactMap { node in
            if actionableRoles.contains(node.role) {
                var missing: [String] = []
                if node.label.isEmpty { missing.append("label") }
                if node.identifier.isEmpty { missing.append("identifier") }
                return missing.isEmpty ? nil : "\(node.path) (\(node.label)) has no \(missing.joined(separator: " or "))"
            }
            if node.role == .image, node.label.isEmpty {
                return "\(node.path) is an unlabeled image (label it, or make it decorative)"
            }
            return nil
        }
    }

    /// The identifiers under `root`.
    func identifiers(under root: Any) -> Set<String> {
        Set(nodes(under: root).map(\.identifier).filter { !$0.isEmpty })
    }

    /// Walks the tree through the element API (`accessibilityChildren()`, `isAccessibilityElement()`,
    /// role, label, identifier): it honors a view's own children override and flattens a plain
    /// view's element descendants. A control answers through its cell, and the accessibility
    /// server reports the control's label and identifier on that cell, so the walk reads them
    /// from the cell's control when the cell has none. (In process, the legacy attribute API
    /// drops both an override and a control's identifier, so it is not used.)
    private func walk(_ object: Any, path: String, into out: inout [AccessibilityNode], seen: inout Set<ObjectIdentifier>) {
        guard out.count < maxNodes, let item = object as? NSObject, let element = item as? NSAccessibilityProtocol,
              seen.insert(ObjectIdentifier(item)).inserted else { return }
        let control = (item as? NSCell)?.controlView
        if let view = (item as? NSView) ?? control, view.isHiddenOrHasHiddenAncestor { return }
        var here = path
        if element.isAccessibilityElement(), let role = element.accessibilityRole() {
            let labels: [String?] = [element.accessibilityLabel(), element.accessibilityTitle(), control?.accessibilityLabel()]
            let identifiers: [String?] = [element.accessibilityIdentifier(), control?.accessibilityIdentifier()]
            let node = AccessibilityNode(role: role, label: labels.compactMap { $0 }.first { !$0.isEmpty } ?? "",
                                         identifier: identifiers.compactMap { $0 }.first { !$0.isEmpty } ?? "",
                                         path: path.isEmpty ? role.rawValue : "\(path) > \(role.rawValue)", element: item)
            out.append(node)
            here = node.path
        }
        for child in element.accessibilityChildren() ?? [] { walk(child, path: here, into: &out, seen: &seen) }
    }
}
