import AppKit
import CmuxSwiftRender

/// Builds a native `NSMenu` from interpreted `.contextMenu` IR on demand.
///
/// SwiftUI's `.contextMenu` on macOS eagerly builds and rebuilds its content
/// on every view update to keep the bridged menu in sync, and each rebuild
/// registers `Observation.ObservationTracking` that is never cancelled — the
/// unbounded multi-GB leak in
/// https://github.com/manaflow-ai/cmux/issues/7345. The IR here is pure data
/// (`RenderNode` values), so the menu can instead be constructed at
/// right-click time by ``RenderNodeContextMenuView``, keeping sidebar renders
/// free of menu hosting entirely.
///
/// Coverage mirrors what the interpreter can put in a `.contextMenu` closure:
/// title and rich-label `Button`s, nested `Menu("…") { … }` submenus,
/// `Divider()`s, informational `Text`/`Label` rows, `.disabled(true)`
/// (inherited by descendants, matching SwiftUI's environment propagation),
/// and `.keyboardShortcut` hints. Container kinds flatten into their
/// children; kinds with no menu representation (shapes, images, gradients)
/// fall back to a text-only row when they carry text, and are skipped
/// otherwise.
@MainActor
struct RenderNodeContextMenuBuilder {
    /// Runs a fired item's ``ButtonAction``; injected once and threaded to
    /// every item target the built menu owns.
    let dispatch: SidebarActionDispatch

    /// Builds a menu whose items mirror `nodes`.
    func makeMenu(nodes: [RenderNode]) -> NSMenu {
        buildMenu(nodes: nodes).menu
    }

    /// Builds a menu once and returns `nil` when the render tree emits no
    /// presentable item. The same append pass both prunes empty submenus and
    /// decides whether the top-level menu should be presented.
    func makeMenuIfPresentable(nodes: [RenderNode]) -> NSMenu? {
        let result = buildMenu(nodes: nodes)
        return result.emitted ? result.menu : nil
    }

    /// Constructs the native menu and records whether its append pass emitted
    /// at least one non-separator item.
    private func buildMenu(nodes: [RenderNode]) -> (menu: NSMenu, emitted: Bool) {
        let menu = NSMenu()
        // Enablement is decided by the IR (`.disabled`), not responder-chain
        // validation, so autoenable would re-disable every targeted item.
        menu.autoenablesItems = false
        let emitted = append(nodes, to: menu, inheritedDisabled: false)
        return (menu, emitted)
    }

    /// Returns whether `nodes` produce at least one non-separator menu item.
    ///
    /// This walks the render IR without constructing `NSMenu` objects or
    /// registering action targets, so hit testing can use the same gate as
    /// presentation without causing menu-building side effects.
    func hasPresentableItems(nodes: [RenderNode]) -> Bool {
        hasPresentableItems(in: nodes)
    }

    private func hasPresentableItems(in nodes: [RenderNode]) -> Bool {
        for node in nodes {
            switch node.kind {
            case .divider:
                // Separators alone do not make a menu useful.
                continue
            case .menu:
                // An empty submenu parent is not useful and must not be
                // emitted. Recurse so nested empty parents are pruned too.
                if hasPresentableItems(in: node.children) { return true }
            case .button, .text, .label:
                // The builder emits these rows even when they are inert or
                // have an empty title, so they are still presentable items.
                return true
            case .vstack, .hstack, .zstack, .lazyVStack, .lazyHStack, .group,
                 .list, .hscroll, .grid, .gridRow, .lazyVGrid, .lazyHGrid,
                 .viewThatFits, .hsplit, .reorderable:
                if hasPresentableItems(in: node.children) { return true }
            case .section:
                if let header = node.text, !header.isEmpty { return true }
                if hasPresentableItems(in: node.children) { return true }
            default:
                // Shapes, images, gradients, progress, spacers, and other
                // unsupported kinds only become rows when they carry text or
                // an action, matching the fallback in `append`.
                if node.action != nil || !renderNodePlainText(of: node).isEmpty {
                    return true
                }
            }
        }
        return false
    }

    @discardableResult
    private func append(_ nodes: [RenderNode], to menu: NSMenu, inheritedDisabled: Bool) -> Bool {
        var emitted = false
        for node in nodes {
            // SwiftUI propagates `.disabled(true)` from a container down the
            // environment; a child cannot re-enable inside a disabled ancestor.
            let disabled = inheritedDisabled || isRenderNodeDisabled(node)
            switch node.kind {
            case .divider:
                menu.addItem(.separator())
            case .menu:
                if let item = submenuItem(for: node, disabled: disabled) {
                    menu.addItem(item)
                    emitted = true
                }
            case .button:
                menu.addItem(actionItem(for: node, disabled: disabled))
                emitted = true
            case .text, .label:
                // Informational rows render like SwiftUI menu text: visible
                // but inert (unless `.onTapGesture` gave the node an action).
                menu.addItem(actionItem(for: node, disabled: disabled))
                emitted = true
            case .vstack, .hstack, .zstack, .lazyVStack, .lazyHStack, .group,
                 .list, .hscroll, .grid, .gridRow, .lazyVGrid, .lazyHGrid,
                 .viewThatFits, .hsplit, .reorderable:
                emitted = append(node.children, to: menu, inheritedDisabled: disabled) || emitted
            case .section:
                if let header = node.text, !header.isEmpty {
                    let item = NSMenuItem(title: header, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                    emitted = true
                }
                emitted = append(node.children, to: menu, inheritedDisabled: disabled) || emitted
            default:
                // Shapes, images, gradients, progress, spacers: no NSMenu
                // representation. Fall back to a text-only row when text (or
                // a tap action) exists rather than re-hosting SwiftUI.
                if node.action != nil || !renderNodePlainText(of: node).isEmpty {
                    menu.addItem(actionItem(for: node, disabled: disabled))
                    emitted = true
                }
            }
        }
        return emitted
    }

    /// A `Menu("…") { … }` node as an item with a recursive submenu. A
    /// disabled menu disables its item and every descendant, matching SwiftUI.
    private func submenuItem(for node: RenderNode, disabled: Bool) -> NSMenuItem? {
        let title = node.text ?? ""
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        guard append(node.children, to: submenu, inheritedDisabled: disabled) else { return nil }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = !disabled
        item.submenu = submenu
        return item
    }

    /// A leaf item: title from the node (or its rich label's text), enabled
    /// when it carries an action and isn't disabled locally or by an
    /// ancestor, firing the node's ``ButtonAction`` through ``dispatch``.
    private func actionItem(for node: RenderNode, disabled: Bool) -> NSMenuItem {
        let title = node.text?.isEmpty == false ? node.text! : renderNodePlainText(of: node.children)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol = renderNodeFirstSystemImage(of: node) {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        applyRenderNodeKeyEquivalent(from: node, to: item)
        if let action = node.action, !disabled {
            let target = RenderMenuItemTarget(action: action, dispatch: dispatch)
            item.target = target
            item.action = #selector(RenderMenuItemTarget.fire(_:))
            // `NSMenuItem.target` is weak; the represented object retains the
            // dispatch target for the menu's lifetime.
            item.representedObject = target
            item.isEnabled = true
        } else {
            item.isEnabled = false
        }
        return item
    }
}

/// Mirrors `RenderNodeView`'s `.disabled` semantics: disabled only when
/// the argument explicitly resolves to `true`.
private func isRenderNodeDisabled(_ node: RenderNode) -> Bool {
    node.modifiers.contains { $0.name == "disabled" && cleanRenderToken($0.firstValue) == "true" }
}

private func cleanRenderToken(_ token: String?) -> String? {
    token?.trimmingCharacters(in: CharacterSet(charactersIn: ".\" "))
}

/// Maps a `.keyboardShortcut` modifier to the item's key-equivalent hint.
@MainActor
private func applyRenderNodeKeyEquivalent(from node: RenderNode, to item: NSMenuItem) {
    guard let modifier = node.modifiers.first(where: { $0.name == "keyboardShortcut" }),
          let key = renderNodeNSKeyEquivalent(modifier.firstValue) else { return }
    item.keyEquivalent = key
    item.keyEquivalentModifierMask = renderNodeNSModifierFlags(modifier.value("modifiers"))
}

/// Resolves a key token (`.return`/`.escape`/arrows/single character) to
/// an `NSMenuItem.keyEquivalent` string.
private func renderNodeNSKeyEquivalent(_ token: String?) -> String? {
    guard var raw = token?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty else { return nil }
    if raw.first == "\"", raw.last == "\"", raw.count >= 2 {
        raw.removeFirst()
        raw.removeLast()
    } else if raw.first == "." {
        raw.removeFirst()
    }
    guard !raw.isEmpty else { return nil }
    switch raw.lowercased() {
    case "return": return "\r"
    case "escape": return "\u{1B}"
    case "space": return " "
    case "tab": return "\t"
    case "delete": return String(UnicodeScalar(NSBackspaceCharacter)!)
    case "uparrow": return String(UnicodeScalar(NSUpArrowFunctionKey)!)
    case "downarrow": return String(UnicodeScalar(NSDownArrowFunctionKey)!)
    case "leftarrow": return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    case "rightarrow": return String(UnicodeScalar(NSRightArrowFunctionKey)!)
    case "deleteforward", "home", "end", "pageup", "pagedown", "clear": return nil
    default: return raw.count == 1 ? raw.lowercased() : nil
    }
}

/// Resolves a `[.command, .shift]`-style token to AppKit modifier flags.
/// SwiftUI's `.keyboardShortcut` defaults to command when unspecified.
private func renderNodeNSModifierFlags(_ source: String?) -> NSEvent.ModifierFlags {
    guard let source = source?.lowercased() else { return [.command] }
    var flags: NSEvent.ModifierFlags = []
    if source.contains("command") { flags.insert(.command) }
    if source.contains("shift") { flags.insert(.shift) }
    if source.contains("option") { flags.insert(.option) }
    if source.contains("control") { flags.insert(.control) }
    return flags
}

/// Concatenated visible text of a subtree, for rich-label buttons and
/// text-only fallbacks.
private func renderNodePlainText(of nodes: [RenderNode]) -> String {
    nodes.map { renderNodePlainText(of: $0) }.filter { !$0.isEmpty }.joined(separator: " ")
}

private func renderNodePlainText(of node: RenderNode) -> String {
    var parts: [String] = []
    if let text = node.text, !text.isEmpty { parts.append(text) }
    parts.append(contentsOf: node.children.map { renderNodePlainText(of: $0) }.filter { !$0.isEmpty })
    return parts.joined(separator: " ")
}

/// First SF Symbol in the subtree (`Label`'s icon or a leading `Image`).
private func renderNodeFirstSystemImage(of node: RenderNode) -> String? {
    if let name = node.systemName, !name.isEmpty { return name }
    for child in node.children {
        if let name = renderNodeFirstSystemImage(of: child) { return name }
    }
    return nil
}
