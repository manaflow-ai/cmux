import AppKit
import WebKit

/// The clickable controls hint mode labels (``WindowHintController``): the
/// window's accessibility tree, walked in process, keeps each shown element
/// whose role a person clicks (buttons, rows, tabs, links, fields, menus),
/// reached through subviews and accessibility children alike.
/// Web views and terminals are skipped: their contents are not controls of
/// the window.
@MainActor
enum WindowHintTargets {
    struct Target: Equatable {
        /// Window coordinates (AppKit, bottom-left origin).
        var rect: CGRect
        var role: String
        var title: String

        var center: NSPoint { NSPoint(x: rect.midX, y: rect.midY) }
    }

    static let clickable: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .link, .disclosureTriangle,
        .textField, .comboBox, .row, .incrementor, .slider, .colorWell,
    ]
    /// Two letters label 14 * 14 controls; more would need three.
    static let limit = WindowHintKeys.alphabet.count * WindowHintKeys.alphabet.count

    /// How many views and elements the last walk visited (`debug.window_hints`).
    private(set) static var lastVisitedCount = 0
    /// What the last walk saw, by "role element? sized?" (`debug.window_hints`).
    private(set) static var lastRoleCounts: [String: Int] = [:]

    /// The window's controls in reading order, clipped to its content.
    static func collect(in content: NSView) -> [Target] {
        guard let window = content.window else { return [] }
        let bounds = content.convert(content.bounds, to: nil)
        var found: [Target] = []
        var seen = Set<[Int]>()
        var stack: [Any] = [content]
        var visited = Set<ObjectIdentifier>()
        var roleCounts: [String: Int] = [:]
        while let next = stack.popLast(), visited.count < 5000, found.count < limit {
            guard visited.insert(ObjectIdentifier(next as AnyObject)).inserted else { continue }
            if let view = next as? NSView {
                guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0.01 else { continue }
                guard !(view is WKWebView), !(view is GhosttyNSView) else { continue }
            }
            let element = next as? NSAccessibilityProtocol
            if element?.isAccessibilityHidden() == true { continue }
            if let element {
                let frame = element.accessibilityFrame()
                let key = "\(element.accessibilityRole()?.rawValue ?? "nil") \(element.isAccessibilityElement() ? "el" : "-") "
                    + (frame.width >= 4 && frame.height >= 4 ? "sized" : "empty")
                roleCounts[key, default: 0] += 1
            } else {
                roleCounts["\(type(of: next)) not-ax", default: 0] += 1
            }
            // Only controls report enabled; custom rows and tabs leave it unset.
            if let element, element.isAccessibilityElement(), let role = element.accessibilityRole(), clickable.contains(role),
               (element as? NSControl)?.isEnabled ?? true {
                let rect = window.convertFromScreen(element.accessibilityFrame()).intersection(bounds)
                let key = [rect.minX, rect.minY, rect.width, rect.height].map { Int($0.rounded()) }
                if rect.width >= 4, rect.height >= 4, seen.insert(key).inserted {
                    found.append(Target(rect: rect, role: role.rawValue, title: describe(element)))
                }
            }
            // A view's subviews plus its accessibility-only children (SwiftUI
            // elements): a SwiftUI host does not list the AppKit views it
            // embeds. Reversed so the walk pops them in reading order.
            var children: [Any] = (next as? NSView)?.subviews ?? []
            children += (element?.accessibilityChildren() ?? []).filter { !($0 is NSView) }
            stack.append(contentsOf: children.reversed())
        }
        lastVisitedCount = visited.count
        lastRoleCounts = roleCounts
        return found
    }

    /// The element's name: its title, label or value, else the first text
    /// under it (a row names itself by its cells).
    private static func describe(_ element: NSAccessibilityProtocol, depth: Int = 0) -> String {
        for text in [element.accessibilityTitle(), element.accessibilityLabel(), element.accessibilityValue() as? String] {
            if let text, !text.isEmpty { return text }
        }
        guard depth < 3 else { return "" }
        for child in element.accessibilityChildren() ?? [] {
            guard let child = child as? NSAccessibilityProtocol else { continue }
            let text = describe(child, depth: depth + 1)
            if !text.isEmpty { return text }
        }
        return ""
    }
}
