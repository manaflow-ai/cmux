import CmuxHomeRender
import CmuxNextApps

/// A chat widget's scene (what the app's `cmux.chat.widget/1` export returned) as the snapshot
/// the Home transcript draws natively (plans/cmux-next/chat-widgets-DESIGN.md section 4): stacks
/// flatten top to bottom, a horizontal stack of buttons stays one row of buttons, and text, rows,
/// badges, dividers and empty states map one to one. Nodes the card does not draw (images,
/// shapes, inputs) are skipped. Pure.
struct ChatWidgetSceneMapping {
    func snapshot(_ scene: AppScene) -> HomeWidgetSnapshot? {
        guard let root = scene.root else { return nil }
        var items: [HomeWidgetItem] = []
        append(root, scene, into: &items)
        return HomeWidgetSnapshot(items: Array(items.prefix(HomeWidgetSnapshot.maxItems)))
    }

    private func append(_ id: String, _ scene: AppScene, into items: inout [HomeWidgetItem]) {
        guard let node = scene[id] else { return }
        switch node.type {
        case .vStack, .lazyVStack, .zStack, .group, .forEach, .panel, .reorderable:
            if node.type == .panel, let title = node.string("title"), !title.isEmpty { items.append(.text(title, style: .headline)) }
            for child in scene.flattenedChildren(of: id) { append(child, scene, into: &items) }
        case .hStack:
            let children = scene.flattenedChildren(of: id)
            let buttons = children.compactMap { child in scene[child].flatMap { button(child, $0) } }
            if !buttons.isEmpty, buttons.count == children.count {
                items.append(.buttons(buttons))
            } else {
                for child in children { append(child, scene, into: &items) }
            }
        case .text:
            guard let text = node.string("text"), !text.isEmpty else { return }
            items.append(.text(text, style: style(node.string("font")), tint: tint(node.string("color")) ?? .primary))
        case .row:
            items.append(.row(node: node.flag("onTap") && !node.flag("disabled") ? id : nil, title: node.string("title") ?? "",
                              subtitle: node.string("subtitle"), symbol: node.string("symbol"),
                              tint: tint(node.string("tint")) ?? .secondary, badge: node.string("badge")))
        case .button:
            if let button = button(id, node) { items.append(.buttons([button])) }
        case .badge:
            guard let text = node.string("text"), !text.isEmpty else { return }
            items.append(.badge(text, tint: tint(node.string("tone")) ?? .secondary))
        case .divider:
            items.append(.divider)
        case .emptyState:
            items.append(.empty(title: node.string("title") ?? "", message: node.string("message"), symbol: node.string("symbol")))
        case .icon, .image, .menu, .spacer, .circle, .capsule, .rectangle, .roundedRectangle, .progressView, .textField,
             .toggle, .slider:
            return
        }
    }

    private func button(_ id: String, _ node: AppSceneNode) -> HomeWidgetButton? {
        guard node.type == .button, let title = node.string("title") ?? node.string("help"), !title.isEmpty else { return nil }
        // `.background("accent")` marks the card's main action.
        return HomeWidgetButton(node: id, title: title, prominent: node.string("background") == "accent",
                                enabled: !node.flag("disabled"))
    }

    private func style(_ font: String?) -> HomeWidgetSnapshot.TextStyle {
        switch font {
        case "headline", "title", "title2", "title3", "largeTitle": .headline
        case "caption", "caption2", "footnote": .caption
        default: .body
        }
    }

    private func tint(_ name: String?) -> HomeWidgetSnapshot.Tint? {
        switch name {
        case "primary", "text.primary": .primary
        case "secondary", "tertiary", "text.secondary", "text.tertiary": .secondary
        case "accent": .accent
        case "success": .success
        case "warning": .warning
        case "danger": .danger
        default: nil
        }
    }
}
