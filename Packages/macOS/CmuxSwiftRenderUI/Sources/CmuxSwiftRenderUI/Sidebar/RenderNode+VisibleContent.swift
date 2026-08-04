import CmuxSwiftRender

/// The interpreter currently admits at most 3,000 produced nodes. Keep the
/// validation walkers bounded above that ceiling so a manually constructed
/// tree cannot make validation consume unbounded memory.
private let validationTreeTraversalLimit = 10_000

extension RenderNode {
    /// Whether this tree produces visible output after rendered modifiers.
    ///
    /// The walk first flattens the tree, then resolves child visibility
    /// bottom-up. It stays iterative because the interpreter deliberately
    /// evaluates deeply nested authored source on a large-stack worker.
    /// Recursing here would move that same tree back onto the caller's smaller
    /// stack.
    var containsVisibleContent: Bool {
        var records: [(
            node: RenderNode,
            childIndices: [Int],
            modifierChildIndices: [[Int]]
        )] = []
        var pending: [(
            node: RenderNode,
            parentIndex: Int?,
            modifierIndex: Int?
        )] = [(self, nil, nil)]

        while let item = pending.popLast() {
            guard records.count < validationTreeTraversalLimit else {
                // An over-limit tree is inconclusive, not evidence of empty
                // output.
                return true
            }

            let nodeIndex = records.count
            records.append((
                node: item.node,
                childIndices: [],
                modifierChildIndices: Array(
                    repeating: [],
                    count: item.node.modifiers.count
                )
            ))
            if let parentIndex = item.parentIndex {
                if let modifierIndex = item.modifierIndex {
                    records[parentIndex]
                        .modifierChildIndices[modifierIndex]
                        .append(nodeIndex)
                } else {
                    records[parentIndex].childIndices.append(nodeIndex)
                }
            }

            var descendants = item.node.children.map {
                (node: $0, parentIndex: Optional(nodeIndex), modifierIndex: Int?.none)
            }
            for (modifierIndex, modifier) in item.node.modifiers.enumerated() {
                guard modifier.hasValidationOutputChildren else { continue }
                descendants.append(contentsOf: modifier.children.map {
                    (
                        node: $0,
                        parentIndex: Optional(nodeIndex),
                        modifierIndex: Optional(modifierIndex)
                    )
                })
            }
            guard descendants.count
                <= validationTreeTraversalLimit - records.count - pending.count
            else {
                return true
            }
            pending.append(contentsOf: descendants)
        }

        // `foreground` output still responds to an enclosing foreground-style
        // modifier. `fixed` output has its own explicit color (a gradient,
        // background, overlay, border, or already-resolved foreground style).
        // Keeping the two bits separate lets a transparent style hide text or
        // a shape without incorrectly hiding an explicit background.
        var output = Array(
            repeating: (foreground: false, fixed: false),
            count: records.count
        )
        for nodeIndex in records.indices.reversed() {
            let record = records[nodeIndex]
            var state = record.node.validationIntrinsicVisibility
            for childIndex in record.childIndices {
                state.foreground = state.foreground || output[childIndex].foreground
                state.fixed = state.fixed || output[childIndex].fixed
            }

            for (modifierIndex, modifier) in record.node.modifiers.enumerated() {
                guard modifier.affectsRenderedOutput(of: record.node.kind),
                      let kind = modifier.renderedKind else {
                    continue
                }
                let childOutput = record.modifierChildIndices[modifierIndex]
                switch kind {
                case .background, .overlay:
                    if modifier.children.isEmpty {
                        state.fixed = state.fixed
                            || dslColorTokenIsVisible(modifier.firstValue)
                    } else {
                        for childIndex in childOutput {
                            state.foreground = state.foreground
                                || output[childIndex].foreground
                            state.fixed = state.fixed || output[childIndex].fixed
                        }
                    }
                case .safeAreaInset:
                    for childIndex in childOutput {
                        state.foreground = state.foreground
                            || output[childIndex].foreground
                        state.fixed = state.fixed || output[childIndex].fixed
                    }
                case .mask:
                    if !modifier.children.isEmpty,
                       !childOutput.contains(where: {
                           output[$0].foreground || output[$0].fixed
                       }) {
                        state = (foreground: false, fixed: false)
                    }
                case .opacity:
                    if let value = modifier.firstValue
                        .flatMap(cleanRenderToken)
                        .flatMap(Double.init),
                       value <= 0 {
                        state = (foreground: false, fixed: false)
                    }
                case .scaleEffect:
                    if let value = modifier.firstValue
                        .flatMap(cleanRenderToken)
                        .flatMap(Double.init),
                       value == 0 {
                        state = (foreground: false, fixed: false)
                    }
                case .foregroundColor, .foregroundStyle, .fill, .tint:
                    let token = cleanRenderToken(modifier.firstValue)
                    if dslColor(token) != nil {
                        if dslColorTokenIsVisible(token) {
                            state.fixed = state.fixed || state.foreground
                        }
                        state.foreground = false
                    }
                case .border:
                    state.fixed = state.fixed
                        || dslResolvedBorder(modifier).isVisible
                default:
                    break
                }
            }

            output[nodeIndex] = state
        }

        return output.first.map { $0.foreground || $0.fixed } ?? false
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
            let leftModifiers = left.modifiers.filter {
                $0.affectsRenderedOutput(of: left.kind)
            }
            let rightModifiers = right.modifiers.filter {
                $0.affectsRenderedOutput(of: right.kind)
            }
            guard left.hasSameNonChildContent(as: right),
                  left.children.count == right.children.count,
                  leftModifiers.count == rightModifiers.count else {
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
            for (leftModifier, rightModifier) in zip(leftModifiers, rightModifiers) {
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

    private var validationIntrinsicVisibility: (
        foreground: Bool,
        fixed: Bool
    ) {
        switch kind {
        case .text:
            return (text?.isEmpty == false, false)
        case .label:
            return (
                text?.isEmpty == false || systemName?.isEmpty == false,
                false
            )
        case .button, .menu, .section:
            return (text?.isEmpty == false, false)
        case .image:
            return (systemName?.isEmpty == false, false)
        case .divider,
             .rectangle,
             .roundedRectangle,
             .capsule,
             .circle,
             .ellipse,
             .unevenRoundedRectangle,
             .progressView:
            return validationShapeOrPrimitiveVisibility
        case .linearGradient,
             .radialGradient,
             .angularGradient:
            return (false, dslResolvedGradient(colors).isVisible)
        case .gauge:
            return (value != nil, false)
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
            return (false, false)
        }
    }

    private var validationShapeOrPrimitiveVisibility: (
        foreground: Bool,
        fixed: Bool
    ) {
        guard isValidationShape else {
            return (true, false)
        }
        if let trim = modifiers.first(where: { $0.renderedKind == .trim }),
           let from = trim.value("from").flatMap(cleanRenderToken).flatMap(Double.init),
           let to = trim.value("to").flatMap(cleanRenderToken).flatMap(Double.init),
           to <= from {
            return (false, false)
        }
        guard let stroke = modifiers.first(where: {
            $0.renderedKind == .stroke || $0.renderedKind == .strokeBorder
        }) else {
            return (true, false)
        }
        let token = cleanRenderToken(stroke.firstValue)
        let resolvedColor = dslColor(token)
        let width = stroke.value("lineWidth")
            .flatMap(cleanRenderToken)
            .flatMap(Double.init)
            ?? 1
        return (
            false,
            width > 0
                && (resolvedColor == nil || dslColorTokenIsVisible(token))
        )
    }

    private var isValidationShape: Bool {
        switch kind {
        case .rectangle,
             .roundedRectangle,
             .capsule,
             .circle,
             .ellipse,
             .unevenRoundedRectangle:
            return true
        default:
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
    var hasValidationOutputChildren: Bool {
        switch renderedKind {
        case .background, .overlay, .safeAreaInset, .mask:
            return true
        default:
            return false
        }
    }
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
