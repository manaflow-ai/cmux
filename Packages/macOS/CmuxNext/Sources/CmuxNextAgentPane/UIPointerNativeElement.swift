import AppKit
import CmuxNextActions
/// One piece of cmux's native UI as Point at Element names it: what it is, what it says, where it is (window
/// coordinates) and how a test or the agent finds it again (its accessibility identifier).
public struct UIPointerNativeElement: Equatable {
    public enum Kind: String {
        case tab = "Tab", tabStrip = "Tab bar", pane = "Pane", paneToolbar = "Pane toolbar"
        case workspace = "Workspace", sidebarItem = "Sidebar item", control = "Control", view = "View"
    }

    public var kind: Kind
    public var title: String
    public var identifier: String?
    public var frame: NSRect
    public var role: String?
    public var viewType: String

    /// The elements under `point` (window coordinates), innermost first. One hit-test and one walk up its
    /// superviews, run only on a picking move; `skip` passes over the picker's own views.
    public static func elements(at point: NSPoint, in window: NSWindow, skip: (NSView) -> Bool = { _ in false }) -> [Self] {
        guard let content = window.contentView,
              let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else { return [] }
        var chain: [NSView] = []
        var next: NSView? = hit
        while let view = next {
            if !skip(view) { chain.append(view) }
            if view === content { break }
            next = view.superview
        }
        let inPane = chain.contains { $0.accessibilityIdentifier().hasPrefix(Prefix.pane) }
        var found: [Self] = []
        for view in chain {
            let identifier = view.accessibilityIdentifier()
            if identifier == Prefix.strip, let tab = tab(in: view, containing: window.convertPoint(toScreen: point), window: window) {
                found.append(tab)
            }
            guard let element = element(for: view, identifier: identifier, inPane: inPane) else { continue }
            // A control and the view it wraps can share a frame; keep the outer, named one.
            if let last = found.last, last.frame == element.frame, last.kind == .control || last.kind == .view {
                found.removeLast()
            }
            found.append(element)
        }
        return found
    }

    /// The menu target's element in `window` (a native menu run carries no point): one walk of the views for its
    /// identifier.
    public static func find(_ target: ActionTargetRef, in window: NSWindow) -> Self? {
        guard let content = window.contentView else { return nil }
        switch target.kind {
        case .tab:
            guard let strip = descendant(of: content, where: { $0.accessibilityIdentifier() == Prefix.strip && !$0.isHiddenOrHasHiddenAncestor }) else { return nil }
            let wanted = Prefix.tab + target.id
            guard let child = (strip.accessibilityChildren() ?? []).first(where: { ($0 as? NSAccessibilityElement)?.accessibilityIdentifier() == wanted }) as? NSAccessibilityElement
            else { return nil }
            return tab(child, window: window)
        case .pane, .workspace, .sidebarItem:
            let prefix = target.kind == .pane ? Prefix.pane : target.kind == .workspace ? Prefix.workspace : Prefix.item
            let wanted = prefix + target.id
            guard let view = descendant(of: content, where: { $0.accessibilityIdentifier() == wanted && !$0.isHiddenOrHasHiddenAncestor })
            else { return nil }
            return element(for: view, identifier: wanted, inPane: false)
        default:
            return nil
        }
    }

    /// The text the agent gets: what it is, how to find it, where it sits, and what holds it.
    public func report(path: [Self]) -> String {
        var lines = ["cmux native UI element", "\(kind.rawValue): \(title)"]
        if let identifier { lines.append("accessibility identifier: \(identifier)") }
        if let role { lines.append("accessibility role: \(role)") }
        lines.append("view: \(viewType)")
        lines.append(String(format: "window frame: x %.0f y %.0f w %.0f h %.0f (bottom-left origin)",
                            frame.minX, frame.minY, frame.width, frame.height))
        let outer = path.drop { $0 != self }.dropFirst()
        if !outer.isEmpty { lines.append("inside: " + outer.map { "\($0.kind.rawValue) \"\($0.title)\"" }.joined(separator: " > ")) }
        return lines.joined(separator: "\n")
    }

    public enum Prefix {
        public static let strip = "cmux.tabs.strip"
        public static let tab = "cmux.tabs.tab."
        public static let pane = "cmux.layout.pane."
        public static let workspace = "cmux.sidebar.workspace."
        public static let item = "cmux.sidebar.item."
        public static let toolbar = "cmux.pane.toolbar."
        public static let nativeToolbar = "cmux.pane.native-toolbar."
    }

    private static func element(for view: NSView, identifier: String, inPane: Bool) -> Self? {
        let kind: Kind
        switch identifier {
        case let id where id.hasPrefix(Prefix.pane): kind = .pane
        case let id where id.hasPrefix(Prefix.workspace): kind = .workspace
        case let id where id.hasPrefix(Prefix.item): kind = .sidebarItem
        case let id where id.hasPrefix(Prefix.toolbar) || id.hasPrefix(Prefix.nativeToolbar): kind = .paneToolbar
        case Prefix.strip: kind = .tabStrip
        case let id where id.hasPrefix("cmux."): kind = .control
        default:
            // Inside a pane only cmux's own named views count; a terminal's or page's insides are not ours to name.
            guard !inPane, view.isAccessibilityElement(), label(of: view) != nil else { return nil }
            kind = .control
        }
        return Self(kind: kind, title: label(of: view) ?? kind.rawValue, identifier: identifier.isEmpty ? nil : identifier,
                    frame: view.convert(view.bounds, to: nil), role: view.accessibilityRole()?.rawValue,
                    viewType: String(describing: type(of: view)))
    }

    /// Tabs are layer cells, not views: the strip names each as an accessibility child (screen frames).
    private static func tab(in strip: NSView, containing screenPoint: NSPoint, window: NSWindow) -> Self? {
        let children = (strip.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        guard let hit = children.first(where: { $0.accessibilityFrame().contains(screenPoint) }) else { return nil }
        return tab(hit, window: window)
    }

    private static func tab(_ element: NSAccessibilityElement, window: NSWindow) -> Self {
        let identifier = element.accessibilityIdentifier()
        let title = element.accessibilityLabel() ?? element.accessibilityTitle() ?? Kind.tab.rawValue
        return Self(kind: identifier.hasSuffix(".close") ? .control : .tab, title: title, identifier: identifier,
                    frame: window.convertFromScreen(element.accessibilityFrame()),
                    role: element.accessibilityRole()?.rawValue, viewType: String(describing: type(of: element)))
    }

    private static func label(of view: NSView) -> String? {
        let text = view.accessibilityLabel() ?? view.accessibilityTitle() ?? (view as? NSControl)?.stringValue
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func descendant(of view: NSView, where match: (NSView) -> Bool) -> NSView? {
        var queue = [view]
        var index = 0
        while index < queue.count {
            let next = queue[index]
            index += 1
            if match(next) { return next }
            queue.append(contentsOf: next.subviews)
        }
        return nil
    }
}
