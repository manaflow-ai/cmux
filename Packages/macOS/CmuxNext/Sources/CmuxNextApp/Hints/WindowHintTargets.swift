import AppKit
import CmuxNextBrowser

/// The clickable controls hint mode labels (``WindowHintController``): the
/// window's accessibility tree, walked in process, keeps each shown element
/// whose role a person clicks (buttons, rows, tabs, links, fields, menus).
/// Web content is skipped here: a web view's tree lives in its page process.
@MainActor
enum WindowHintTargets {
    struct Target: Equatable {
        /// Window coordinates (AppKit, bottom-left origin).
        var rect: CGRect
        var role: String
        var title: String

        var center: NSPoint { NSPoint(x: rect.midX, y: rect.midY) }
        /// The session's key for this target (its labels are per point).
        var point: LinkHintTarget { LinkHintTarget(x: rect.midX, y: rect.midY, left: rect.minX, top: rect.maxY) }
    }

    static let clickable: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .link, .disclosureTriangle,
        .textField, .comboBox, .row, .incrementor, .slider, .colorWell,
    ]
    /// Two letters label 14 * 14 controls; more would need three.
    static let limit = LinkHintSession.alphabet.count * LinkHintSession.alphabet.count
    /// Views whose subtree is another process's (web pages).
    private static let remoteViewNames = ["WKWebView", "CEF", "Chromium", "RenderWidgetHost"]

    static func collect(in content: NSView) -> [Target] {
        guard let window = content.window else { return [] }
        let bounds = content.convert(content.bounds, to: nil)
        var found: [Target] = []
        var seen = Set<[Int]>()
        var stack: [Any] = [content]
        var visited = 0
        while let next = stack.popLast(), visited < 5000, found.count < limit {
            visited += 1
            if let view = next as? NSView {
                guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0.01 else { continue }
                let name = NSStringFromClass(type(of: view))
                guard !remoteViewNames.contains(where: name.contains) else { continue }
            }
            guard let element = next as? NSAccessibilityProtocol, !element.isAccessibilityHidden() else { continue }
            if element.isAccessibilityElement(), let role = element.accessibilityRole(), clickable.contains(role),
               element.isAccessibilityEnabled() {
                let rect = window.convertFromScreen(element.accessibilityFrame()).intersection(bounds)
                let key = [rect.minX, rect.minY, rect.width, rect.height].map { Int($0.rounded()) }
                if rect.width >= 4, rect.height >= 4, seen.insert(key).inserted {
                    found.append(Target(rect: rect, role: role.rawValue, title: describe(element)))
                }
            }
            // Children in reverse so the walk pops them in reading order.
            stack.append(contentsOf: (element.accessibilityChildren() ?? []).reversed())
        }
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
