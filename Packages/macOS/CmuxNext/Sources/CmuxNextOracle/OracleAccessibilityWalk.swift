#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

/// The `ax` facet's walk (``OracleAccessibilityFacet``): a window's shown accessibility tree, as an AX client sees
/// it, keeping each element whose role is in ``roles`` and the one with the keyboard focus, in preorder. The nodes
/// it drops promote their children (Chrome's filtered dump, ui/accessibility/platform/inspect/ax_tree_formatter_mac.mm).
/// A remote view's subtree is its page process's (the `webviews` facet); a remote view that holds the focus is kept
/// as a leaf, so the focus stays in the tree.
public struct OracleAccessibilityWalk: Sendable {
    /// The roles kept besides the focused element (`AXButton`, `AXRow`).
    public var roles: Set<String>
    /// Whether a view's subtree lives in another process (a web view, a Chromium page).
    public var isRemote: @MainActor @Sendable (NSView) -> Bool
    /// More elements than this under one window fails the snapshot rather than recording part of the tree.
    public var limit: Int

    public init(roles: Set<String>, limit: Int = 50_000, isRemote: @escaping @MainActor @Sendable (NSView) -> Bool) {
        self.roles = roles
        self.limit = limit
        self.isRemote = isRemote
    }

    /// `window`'s kept elements, then those of its sheet and its shown child windows (a panel over it) that its own
    /// tree does not hold (AppKit makes an attached sheet a child of its window). Each element is walked once.
    @MainActor
    public func nodes(in window: NSWindow) throws(OracleFacetError) -> [OracleAccessibilityFacet.Node] {
        let roots = [window] + [window.attachedSheet].compactMap { $0 } + (window.childWindows ?? []).filter { $0.isVisible }
        var walk = Walk()
        for root in roots where walk.seen.insert(ObjectIdentifier(root)).inserted {
            try visit(root, into: &walk)
        }
        return walk.nodes
    }

    private struct Walk {
        var nodes: [OracleAccessibilityFacet.Node] = []
        var seen: Set<ObjectIdentifier> = []
    }

    private struct Item {
        var element: Any
        var depth: Int
        /// The view with the keyboard focus in the element's window.
        var focus: NSView?
    }

    @MainActor
    private func visit(_ root: NSWindow, into walk: inout Walk) throws(OracleFacetError) {
        var visited = 0
        var stack = Self.children(of: root, depth: 0, focus: Self.focusedView(of: root))
        while let item = stack.popLast() {
            visited += 1
            guard visited <= limit else {
                throw OracleFacetError("window \(root.windowNumber) has more than \(limit) accessibility elements")
            }
            if let object = item.element as? NSObject, !walk.seen.insert(ObjectIdentifier(object)).inserted { continue }
            // A sheet or panel in the tree: its own first responder holds its focus.
            if let window = item.element as? NSWindow {
                stack += Self.children(of: window, depth: item.depth, focus: Self.focusedView(of: window))
                continue
            }
            let view = item.element as? NSView
            // visibility-walk-allow: the AX read keeps only what shows, as an AX client sees it; no work is deferred
            if let view, view.isHiddenOrHasHiddenAncestor || view.alphaValue <= 0.01 { continue }
            guard let element = item.element as? NSAccessibilityProtocol, !element.isAccessibilityHidden() else { continue }
            let remote = view.map { isRemote($0) } ?? false
            // A page's focus is inside its view's subtree, which the walk leaves to the page.
            let holdsFocus = view.map { remote ? item.focus?.isDescendant(of: $0) == true : $0 === item.focus } ?? false
            let focused = holdsFocus || element.isAccessibilityFocused()
            var childDepth = item.depth
            if let role = element.accessibilityRole()?.rawValue,
               focused || (element.isAccessibilityElement() && !remote && roles.contains(role)) {
                walk.nodes.append(OracleAccessibilityFacet.Node(
                    role: role, identifier: Self.identifier(of: element), names: Self.names(of: element),
                    // Only controls report enabled; custom rows, tabs and terminals leave AXEnabled unset (false).
                    enabled: (element as? NSControl)?.isEnabled ?? true, focused: focused, depth: item.depth))
                childDepth += 1
            }
            guard !remote else { continue }
            stack += Self.children(of: element, depth: childDepth, focus: item.focus)
        }
    }

    /// `element`'s children, reversed so the walk pops them in reading order.
    @MainActor
    private static func children(of element: NSAccessibilityProtocol, depth: Int, focus: NSView?) -> [Item] {
        (element.accessibilityChildren() ?? []).reversed().map { Item(element: $0, depth: depth, focus: focus) }
    }

    /// The view with the keyboard focus: the first responder, or the text field a field editor edits for it.
    @MainActor
    private static func focusedView(of window: NSWindow) -> NSView? {
        guard let responder = window.firstResponder as? NSView else { return nil }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { return field }
        return responder
    }

    @MainActor
    private static func identifier(of element: NSAccessibilityProtocol) -> String? {
        let identifier: String? = element.accessibilityIdentifier()
        return identifier?.isEmpty == false ? identifier : nil
    }

    /// The texts that name `element`, in the order the facet tries them for a localization key.
    @MainActor
    private static func names(of element: NSAccessibilityProtocol) -> [String] {
        let texts: [String?] = [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityPlaceholderValue(),
                                element.accessibilityHelp()]
        return texts.compactMap { $0 }.filter { !$0.isEmpty }
    }
}
#endif
