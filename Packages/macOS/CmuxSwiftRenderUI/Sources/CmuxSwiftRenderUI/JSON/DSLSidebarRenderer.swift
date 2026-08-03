import CmuxSwiftRender

/// Lowers the declarative JSON tree into the same render IR used by interpreted sources.
enum DSLSidebarRenderer {
    static func renderNode(_ node: DSLNode) -> RenderNode {
        let kind: RenderNode.Kind
        switch node.type {
        case .vstack: kind = .vstack
        case .hstack: kind = .hstack
        case .zstack: kind = .zstack
        case .text: kind = .text
        case .button: kind = .button
        case .image: kind = .image
        case .spacer: kind = .spacer
        case .divider: kind = .divider
        }

        var modifiers: [RenderModifier] = []
        if let padding = node.padding {
            modifiers.append(
                RenderModifier(name: "padding", args: [.init(label: nil, value: String(padding))])
            )
        }
        if let color = node.color {
            modifiers.append(
                RenderModifier(name: "foregroundColor", args: [.init(label: nil, value: color)])
            )
        }
        if let background = node.background {
            modifiers.append(
                RenderModifier(name: "background", args: [.init(label: nil, value: background)])
            )
        }
        if node.font != nil || node.size != nil || node.weight != nil {
            let fontToken =
                node.font ?? "system(size: \(node.size ?? 13), weight: .\(node.weight ?? "regular"))"
            modifiers.append(RenderModifier(name: "font", args: [.init(label: nil, value: fontToken)]))
        }

        return RenderNode(
            kind: kind,
            text: node.type == .button ? (node.title ?? node.text) : node.text,
            systemName: node.systemName,
            spacing: node.type == .spacer ? node.size : node.spacing,
            children: (node.children ?? []).map(renderNode),
            modifiers: modifiers,
            action: node.action?.buttonAction
        )
    }
}
