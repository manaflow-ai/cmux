import AppKit
import WebKit

/// The clickable controls hint mode labels (``WindowHintController``): the
/// window's accessibility tree, walked in process, keeps each shown element
/// whose role a person clicks (buttons, rows, tabs, links, fields, menus),
/// reached through subviews and accessibility children alike. In process a
/// SwiftUI host shows its controls only as AXUnknown elements, so SwiftUI
/// controls name themselves with a ``WindowHintRegion`` marker view.
/// Terminals are skipped: their contents are not controls of the window.
/// Web views are asked for their page's elements instead
/// (``WindowHintPages``).
@MainActor
enum WindowHintTargets {
    struct Target: Equatable {
        /// Window coordinates (AppKit, bottom-left origin).
        var rect: CGRect
        var role: String
        var title: String
        /// A web page element: clicked inside its page, not with a window mouse event.
        var page: WindowHintPageElement? = nil

        var center: NSPoint { NSPoint(x: rect.midX, y: rect.midY) }
    }

    static let clickable: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .link, .disclosureTriangle,
        .textField, .comboBox, .row, .incrementor, .slider, .colorWell,
    ]
    /// Two letters label 14 * 14 controls; more would need three.
    static let limit = WindowHintKeys.alphabet.count * WindowHintKeys.alphabet.count

    /// The window's controls in reading order, clipped to the window. The
    /// walk starts at the frame view above `content`, so the titlebar's
    /// accessory controls count; the traffic lights do not (told by subrole:
    /// the frame view lists them as accessibility elements, not as its views).
    static func collect(in content: NSView) -> [Target] {
        guard let window = content.window else { return [] }
        let root = content.superview ?? content
        let bounds = root.convert(root.bounds, to: nil)
        let trafficLights: Set<NSAccessibility.Subrole> = [.closeButton, .minimizeButton, .zoomButton, .fullScreenButton]
        var found: [Target] = []
        var seen = Set<[Int]>()
        var stack: [Any] = [root]
        var visited = Set<ObjectIdentifier>()
        while let next = stack.popLast(), visited.count < 5000, found.count < limit {
            guard visited.insert(ObjectIdentifier(next as AnyObject)).inserted else { continue }
            if let view = next as? NSView {
                guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0.01 else { continue }
                guard !(view is WKWebView), !(view is GhosttyNSView) else { continue }
                if let marker = view as? WindowHintRegion.MarkerView {
                    let rect = marker.convert(marker.bounds, to: nil).intersection(bounds)
                    let key = [rect.minX, rect.minY, rect.width, rect.height].map { Int($0.rounded()) }
                    if marker.isEnabled, rect.width >= 4, rect.height >= 4, seen.insert(key).inserted {
                        found.append(Target(rect: rect, role: NSAccessibility.Role.button.rawValue, title: marker.title))
                    }
                    continue
                }
            }
            let element = next as? NSAccessibilityProtocol
            if element?.isAccessibilityHidden() == true { continue }
            if let subrole = element?.accessibilitySubrole(), trafficLights.contains(subrole) { continue }
            // Only controls report enabled; custom rows and tabs leave it unset.
            if let element, element.isAccessibilityElement(), let role = element.accessibilityRole(), clickable.contains(role),
               (element as? NSControl)?.isEnabled ?? true {
                let rect = window.convertFromScreen(element.accessibilityFrame()).intersection(bounds)
                let key = [rect.minX, rect.minY, rect.width, rect.height].map { Int($0.rounded()) }
                if rect.width >= 4, rect.height >= 4, seen.insert(key).inserted {
                    found.append(Target(rect: rect, role: role.rawValue, title: describe(element)))
                }
            }
            // A table's rows are private accessibility objects; label the
            // shown rows from the table itself (the workspace sidebar).
            if let table = next as? NSTableView {
                let shown = table.rows(in: table.visibleRect)
                for row in shown.lowerBound..<shown.upperBound where found.count < limit {
                    let rect = table.convert(table.rect(ofRow: row), to: nil).intersection(bounds)
                    let key = [rect.minX, rect.minY, rect.width, rect.height].map { Int($0.rounded()) }
                    guard rect.width >= 4, rect.height >= 4, seen.insert(key).inserted else { continue }
                    let title = table.rowView(atRow: row, makeIfNecessary: false).map { text(in: $0) } ?? ""
                    found.append(Target(rect: rect, role: NSAccessibility.Role.row.rawValue, title: title))
                }
            }
            // A view's subviews plus its accessibility-only children (SwiftUI
            // elements): a SwiftUI host does not list the AppKit views it
            // embeds. Reversed so the walk pops them in reading order.
            var children: [Any] = (next as? NSView)?.subviews ?? []
            children += (element?.accessibilityChildren() ?? []).filter { !($0 is NSView) }
            stack.append(contentsOf: children.reversed())
        }
        return found
    }

    /// The first text shown under `view`: a label's string or an
    /// accessibility element's title, label or value.
    private static func text(in view: NSView, depth: Int = 0) -> String {
        if let field = view as? NSTextField, !field.stringValue.isEmpty { return field.stringValue }
        let own = describe(view, depth: 3)
        if !own.isEmpty { return own }
        guard depth < 8 else { return "" }
        for child in (view.accessibilityChildren() ?? []).compactMap({ $0 as? NSAccessibilityProtocol }) where !(child is NSView) {
            let name = describe(child)
            if !name.isEmpty { return name }
        }
        for subview in view.subviews {
            let shown = text(in: subview, depth: depth + 1)
            if !shown.isEmpty { return shown }
        }
        return ""
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
