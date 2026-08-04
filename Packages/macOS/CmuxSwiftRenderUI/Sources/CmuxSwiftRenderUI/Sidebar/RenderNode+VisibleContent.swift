import CmuxSwiftRender

/// The interpreter currently admits at most 3,000 produced nodes. Keep the
/// validation walkers bounded above that ceiling so a manually constructed
/// tree cannot make validation consume unbounded memory.
private let validationTreeTraversalLimit = 10_000

extension RenderNode {
    /// Whether this tree contains a primitive that can visibly render.
    ///
    /// This walk stays iterative because the interpreter deliberately evaluates
    /// deeply nested authored source on a large-stack worker. Recursing here
    /// would move that same tree back onto the caller's smaller stack.
    var containsVisibleContent: Bool {
        var pending = [self]
        var inspectedCount = 0

        while let node = pending.popLast() {
            inspectedCount += 1
            guard inspectedCount <= validationTreeTraversalLimit else {
                // An over-limit tree is inconclusive, not evidence of empty output.
                return true
            }
            if node.isVisiblePrimitive {
                return true
            }
            guard enqueueValidationNodes(
                node.children,
                onto: &pending,
                inspectedCount: inspectedCount
            ) else {
                return true
            }
            for modifier in node.modifiers {
                if modifier.hasVisibleValueDecoration {
                    return true
                }
                guard enqueueValidationNodes(
                    modifier.visibleChildNodes,
                    onto: &pending,
                    inspectedCount: inspectedCount
                ) else {
                    return true
                }
            }
        }

        return false
    }

    /// Compares rendered output without recursing on the caller's stack.
    ///
    /// Returning `false` when the explicit traversal bound is exceeded keeps
    /// the optional-data coverage warning conservative: an inconclusive
    /// comparison must not be reported as unchanged output.
    func hasSameValidationOutput(as other: RenderNode) -> Bool {
        var pending: [(RenderNode, RenderNode)] = [(self, other)]
        var inspectedCount = 0

        while let (left, right) = pending.popLast() {
            inspectedCount += 1
            guard inspectedCount <= validationTreeTraversalLimit else {
                return false
            }
            guard left.hasSameNonChildContent(as: right),
                  left.children.count == right.children.count,
                  left.modifiers.count == right.modifiers.count else {
                return false
            }

            guard enqueueValidationNodePairs(
                left.children,
                right.children,
                onto: &pending,
                inspectedCount: inspectedCount
            ) else {
                return false
            }
            for (leftModifier, rightModifier) in zip(left.modifiers, right.modifiers) {
                guard leftModifier.name == rightModifier.name,
                      leftModifier.args == rightModifier.args,
                      leftModifier.children.count == rightModifier.children.count,
                      enqueueValidationNodePairs(
                          leftModifier.children,
                          rightModifier.children,
                          onto: &pending,
                          inspectedCount: inspectedCount
                      ) else {
                    return false
                }
            }
        }

        return true
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
             .linearGradient,
             .radialGradient,
             .angularGradient:
            return true
        case .gauge:
            return value != nil
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

    private func hasSameNonChildContent(as other: RenderNode) -> Bool {
        kind == other.kind
            && text == other.text
            && systemName == other.systemName
            && spacing == other.spacing
            && cornerRadius == other.cornerRadius
            && value == other.value
            && colors == other.colors
            && points == other.points
            && action == other.action
            && reorder == other.reorder
    }
}

private extension RenderModifier {
    var visibleChildNodes: [RenderNode] {
        switch name {
        case "background", "overlay", "safeAreaInset":
            return children
        default:
            // Masks only constrain existing output, and context-menu content
            // is not visible until interaction.
            return []
        }
    }

    var hasVisibleValueDecoration: Bool {
        (name == "background" || name == "overlay")
            && dslColorTokenIsVisible(firstValue)
    }
}

private func enqueueValidationNodes(
    _ nodes: [RenderNode],
    onto pending: inout [RenderNode],
    inspectedCount: Int
) -> Bool {
    guard nodes.count <= validationTreeTraversalLimit - inspectedCount - pending.count else {
        return false
    }
    pending.append(contentsOf: nodes)
    return true
}

private func enqueueValidationNodePairs(
    _ leftNodes: [RenderNode],
    _ rightNodes: [RenderNode],
    onto pending: inout [(RenderNode, RenderNode)],
    inspectedCount: Int
) -> Bool {
    guard leftNodes.count == rightNodes.count,
          leftNodes.count <= validationTreeTraversalLimit - inspectedCount - pending.count else {
        return false
    }
    for (left, right) in zip(leftNodes, rightNodes) {
        pending.append((left, right))
    }
    return true
}
