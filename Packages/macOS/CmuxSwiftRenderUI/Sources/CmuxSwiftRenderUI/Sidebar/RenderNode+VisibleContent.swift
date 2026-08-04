import CmuxSwiftRender

extension RenderNode {
    /// Whether this tree contains a primitive that can visibly render.
    var containsVisibleContent: Bool {
        if isVisiblePrimitive {
            return true
        }
        if children.contains(where: \.containsVisibleContent) {
            return true
        }
        return modifiers.contains { modifier in
            modifier.children.contains(where: \.containsVisibleContent)
        }
    }

    private var isVisiblePrimitive: Bool {
        switch kind {
        case .text:
            return text?.isEmpty == false
        case .label:
            return text?.isEmpty == false || systemName?.isEmpty == false
        case .button, .menu, .section:
            return text?.isEmpty == false
        case .image:
            return systemName?.isEmpty == false
        case .divider,
             .rectangle,
             .roundedRectangle,
             .capsule,
             .circle,
             .ellipse,
             .unevenRoundedRectangle,
             .progressView,
             .gauge,
             .linearGradient,
             .radialGradient,
             .angularGradient:
            return true
        case .vstack,
             .hstack,
             .zstack,
             .lazyVStack,
             .lazyHStack,
             .group,
             .list,
             .hscroll,
             .grid,
             .gridRow,
             .lazyVGrid,
             .lazyHGrid,
             .viewThatFits,
             .hsplit,
             .reorderable,
             .spacer:
            return false
        }
    }
}
