public import AppKit
public import CmuxNextActions

/// One piece of cmux's native UI as Point at Element names it: what it is, what it says, where it is (window
/// coordinates) and how a test or the agent finds it again (its accessibility identifier).
public struct UIPointerNativeElement: Equatable {
    public enum Kind: String {
        case tab = "Tab", tabStrip = "Tab bar", pane = "Pane", paneToolbar = "Pane toolbar"
        case workspace = "Workspace", sidebarItem = "Sidebar item", control = "Control", view = "View"

        /// The kind as the outline's chip shows it, in the app's language; the report keeps `rawValue` (stable English).
        public var displayName: String {
            switch self {
            case .tab: String(localized: "agentPane.pointer.kind.tab", defaultValue: "Tab", bundle: .localizedModule)
            case .tabStrip: String(localized: "agentPane.pointer.kind.tabStrip", defaultValue: "Tab bar", bundle: .localizedModule)
            case .pane: String(localized: "agentPane.pointer.kind.pane", defaultValue: "Pane", bundle: .localizedModule)
            case .paneToolbar:
                String(localized: "agentPane.pointer.kind.paneToolbar", defaultValue: "Pane toolbar", bundle: .localizedModule)
            case .workspace: String(localized: "agentPane.pointer.kind.workspace", defaultValue: "Workspace", bundle: .localizedModule)
            case .sidebarItem:
                String(localized: "agentPane.pointer.kind.sidebarItem", defaultValue: "Sidebar item", bundle: .localizedModule)
            case .control: String(localized: "agentPane.pointer.kind.control", defaultValue: "Control", bundle: .localizedModule)
            case .view: String(localized: "agentPane.pointer.kind.view", defaultValue: "View", bundle: .localizedModule)
            }
        }
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
        var next: NSView? = row(under: point, in: hit) ?? hit
        while let view = next {
            if !skip(view) { chain.append(view) }
            if view === content { break }
            next = view.superview
        }
        let inPane = chain.contains { $0.accessibilityIdentifier().hasPrefix(Self.paneID) }
        var found: [Self] = []
        for view in chain {
            let identifier = view.accessibilityIdentifier()
            if isTabList(view, identifier: identifier), let tab = tab(in: view, containing: window.convertPoint(toScreen: point), window: window) {
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
            // Every pane has its own strip (and may show a vertical list): the tab is in whichever names it.
            let wanted: Set = [Self.tabID + target.id, Self.verticalTabID + target.id]
            var child: NSAccessibilityElement?
            _ = descendant(of: content) { view in
                guard isTabList(view, identifier: view.accessibilityIdentifier()), !view.isHiddenOrHasHiddenAncestor else { return false }
                child = (view.accessibilityChildren() ?? []).lazy.compactMap { $0 as? NSAccessibilityElement }
                    .first { $0.accessibilityIdentifier().map(wanted.contains) ?? false }
                return child != nil
            }
            return child.map { tab($0, window: window) }
        case .pane, .workspace, .sidebarItem:
            let prefix = target.kind == .pane ? Self.paneID : target.kind == .workspace ? Self.workspaceID : Self.itemID
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

    /// The accessibility identifiers (and identifier prefixes) cmux's native views carry.
    static let stripID = "cmux.tabs.strip"
    static let tabID = "cmux.tabs.tab."
    static let verticalTabID = "cmux.tabs.vertical."
    static let paneID = "cmux.layout.pane."
    static let workspaceID = "cmux.sidebar.workspace."
    static let itemID = "cmux.sidebar.item."
    static let toolbarID = "cmux.pane.toolbar."
    static let nativeToolbarID = "cmux.pane.native-toolbar."

    private static func element(for view: NSView, identifier: String, inPane: Bool) -> Self? {
        let kind: Kind
        switch identifier {
        case let id where id.hasPrefix(Self.paneID): kind = .pane
        // A row's own buttons extend its identifier (`cmux.sidebar.workspace.<id>.close`): those are controls. The
        // row itself may be any view, a label included, so only a button counts.
        case let id where id.hasPrefix(Self.workspaceID): kind = view is NSButton ? .control : .workspace
        case let id where id.hasPrefix(Self.itemID): kind = view is NSButton ? .control : .sidebarItem
        case let id where id.hasPrefix(Self.toolbarID) || id.hasPrefix(Self.nativeToolbarID): kind = .paneToolbar
        case Self.stripID: kind = .tabStrip
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
        // NSAccessibilityElement's identifier is optional (NSView's is not).
        let identifier = element.accessibilityIdentifier().flatMap { $0.isEmpty ? nil : $0 }
        let title = element.accessibilityLabel() ?? element.accessibilityTitle() ?? Kind.tab.rawValue
        let isTab = identifier.map { $0.hasPrefix(Self.tabID) || $0.hasPrefix(Self.verticalTabID) } ?? false
        return Self(kind: isTab ? .tab : .control, title: title, identifier: identifier,
                    frame: window.convertFromScreen(element.accessibilityFrame()),
                    role: element.accessibilityRole()?.rawValue, viewType: String(describing: type(of: element)))
    }

    /// A tab strip or the vertical tab list: tabs are its accessibility children, not views.
    private static func isTabList(_ view: NSView, identifier: String) -> Bool {
        identifier == Self.stripID || view.accessibilityRole() == .tabGroup
    }

    private static func label(of view: NSView) -> String? {
        let text = view.accessibilityLabel() ?? view.accessibilityTitle() ?? (view as? NSControl)?.stringValue
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A sidebar row answers no hit-test over its body (the list owns the click, `SidebarRowView.hitTest`), so the
    /// hit lands on the list: the named row of `hit`'s own subviews that holds `point` (window coordinates) is the
    /// one under the pointer. One pass over `hit`'s subviews, topmost first; nil when none is a row.
    private static func row(under point: NSPoint, in hit: NSView) -> NSView? {
        for view in hit.subviews.reversed() where !view.isHidden && view.alphaValue > 0 && !(view is NSButton) {
            let identifier = view.accessibilityIdentifier()
            guard identifier.hasPrefix(Self.workspaceID) || identifier.hasPrefix(Self.itemID) else { continue }
            if view.convert(view.bounds, to: nil).contains(point) { return view }
        }
        return nil
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
