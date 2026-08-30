import CmuxSwiftRender

/// Compares and classifies render trees using the renderer's resolved effects.
struct RenderOutputInspector {
    private typealias Visibility = (
        foreground: Bool,
        fixed: Bool
    )

    private let styleResolver: RenderStyleResolver
    private let traversalLimit: Int

    /// Creates an inspector with an explicit renderer-style dependency.
    ///
    /// The interpreter admits at most 3,000 produced nodes. The larger default
    /// keeps manually constructed trees bounded without rejecting interpreter
    /// output.
    init(
        styleResolver: RenderStyleResolver,
        traversalLimit: Int = 10_000
    ) {
        self.styleResolver = styleResolver
        self.traversalLimit = traversalLimit
    }

    /// Whether a tree produces visible output after rendered modifiers.
    ///
    /// The walk first flattens the tree, then resolves child visibility
    /// bottom-up. It stays iterative because the interpreter deliberately
    /// evaluates deeply nested authored source on a large-stack worker.
    func containsVisibleContent(in root: RenderNode) -> Bool {
        var records:
            [(
                node: RenderNode,
                childIndices: [Int],
                modifierChildIndices: [[Int]]
            )] = []
        var pending:
            [(
                node: RenderNode,
                parentIndex: Int?,
                modifierIndex: Int?
            )] = [(root, nil, nil)]

        while let item = pending.popLast() {
            guard records.count < traversalLimit else {
                // An over-limit tree is inconclusive, not evidence of empty
                // output.
                return true
            }

            let nodeIndex = records.count
            records.append(
                (
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
                (
                    node: $0,
                    parentIndex: Optional(nodeIndex),
                    modifierIndex: Int?.none
                )
            }
            for (modifierIndex, modifier) in item.node.modifiers.enumerated() {
                guard modifier.hasValidationOutputChildren else {
                    continue
                }
                descendants.append(
                    contentsOf: modifier.children.map {
                        (
                            node: $0,
                            parentIndex: Optional(nodeIndex),
                            modifierIndex: Optional(modifierIndex)
                        )
                    })
            }
            guard
                descendants.count
                    <= traversalLimit - records.count - pending.count
            else {
                return true
            }
            pending.append(contentsOf: descendants)
        }

        // `foreground` output still responds to an enclosing foreground style.
        // `fixed` output has an explicit color such as a gradient, background,
        // overlay, border, or already-resolved foreground style.
        var output = Array(
            repeating: (foreground: false, fixed: false),
            count: records.count
        )
        for nodeIndex in records.indices.reversed() {
            let record = records[nodeIndex]
            var state = intrinsicVisibility(of: record.node)
            for childIndex in record.childIndices {
                state.foreground =
                    state.foreground
                    || output[childIndex].foreground
                state.fixed = state.fixed || output[childIndex].fixed
            }

            for (modifierIndex, capturedModifier) in record.node.modifiers.enumerated() {
                guard
                    let modifier =
                        capturedModifier.normalizedRenderedEffect(
                            on: record.node.kind,
                            using: styleResolver
                        )
                else {
                    continue
                }
                applyVisibility(
                    modifier,
                    modifierChildIndices:
                        record.modifierChildIndices[modifierIndex],
                    resolvedOutput: output,
                    to: &state
                )
            }
            output[nodeIndex] = state
        }

        return output.first.map {
            $0.foreground || $0.fixed
        } ?? false
    }

    /// Compares rendered output without recursing on the caller's stack.
    ///
    /// Returning `false` when the explicit traversal bound is exceeded keeps
    /// optional-data warnings conservative: an inconclusive comparison is not
    /// reported as unchanged output.
    func hasSameValidationOutput(
        _ root: RenderNode,
        as other: RenderNode
    ) -> Bool {
        var pending: [(RenderNode, RenderNode)] = [(root, other)]
        var inspectedCount = 0

        while let (left, right) = pending.popLast() {
            inspectedCount += 1
            guard inspectedCount <= traversalLimit else {
                return false
            }
            let leftModifiers = left.modifiers.compactMap {
                $0.normalizedRenderedEffect(
                    on: left.kind,
                    using: styleResolver
                )
            }
            let rightModifiers = right.modifiers.compactMap {
                $0.normalizedRenderedEffect(
                    on: right.kind,
                    using: styleResolver
                )
            }
            guard hasSameNonChildContent(left, as: right),
                left.children.count == right.children.count,
                leftModifiers.count == rightModifiers.count
            else {
                return false
            }

            guard
                enqueueNodePairs(
                    left.children,
                    right.children,
                    onto: &pending,
                    inspectedCount: inspectedCount
                )
            else {
                return false
            }
            for (leftModifier, rightModifier) in zip(leftModifiers, rightModifiers) {
                guard leftModifier.name == rightModifier.name,
                    leftModifier.args == rightModifier.args,
                    leftModifier.children.count
                        == rightModifier.children.count,
                    enqueueNodePairs(
                        leftModifier.children,
                        rightModifier.children,
                        onto: &pending,
                        inspectedCount: inspectedCount
                    )
                else {
                    return false
                }
            }
        }

        return true
    }

    /// Applies one normalized modifier to the node's accumulated visibility.
    private func applyVisibility(
        _ modifier: RenderModifier,
        modifierChildIndices: [Int],
        resolvedOutput: [Visibility],
        to state: inout Visibility
    ) {
        guard let kind = modifier.renderedKind else { return }
        switch kind {
        case .background, .overlay:
            if modifier.children.isEmpty {
                state.fixed =
                    state.fixed
                    || styleResolver.colorIsVisible(modifier.firstValue)
            } else {
                merge(
                    modifierChildIndices,
                    from: resolvedOutput,
                    into: &state
                )
            }
        case .safeAreaInset:
            merge(
                modifierChildIndices,
                from: resolvedOutput,
                into: &state
            )
        case .mask:
            if !modifier.children.isEmpty,
                !modifierChildIndices.contains(where: {
                    resolvedOutput[$0].foreground
                        || resolvedOutput[$0].fixed
                })
            {
                state = (foreground: false, fixed: false)
            }
        case .opacity:
            if let value = modifier.firstValue
                .flatMap(styleResolver.cleanToken)
                .flatMap(Double.init),
                value <= 0
            {
                state = (foreground: false, fixed: false)
            }
        case .scaleEffect:
            if let value = modifier.firstValue
                .flatMap(styleResolver.cleanToken)
                .flatMap(Double.init),
                value == 0
            {
                state = (foreground: false, fixed: false)
            }
        case .foregroundColor, .foregroundStyle, .fill, .tint:
            if styleResolver.color(modifier.firstValue) != nil {
                if styleResolver.colorIsVisible(modifier.firstValue) {
                    state.fixed = state.fixed || state.foreground
                }
                state.foreground = false
            }
        case .border:
            state.fixed =
                state.fixed
                || styleResolver.border(modifier).isVisible
        default:
            break
        }
    }

    /// Merges resolved modifier-child output into a parent visibility state.
    private func merge(
        _ childIndices: [Int],
        from output: [Visibility],
        into state: inout Visibility
    ) {
        for childIndex in childIndices {
            state.foreground =
                state.foreground
                || output[childIndex].foreground
            state.fixed = state.fixed || output[childIndex].fixed
        }
    }

    /// Classifies output contributed before children and modifiers are applied.
    private func intrinsicVisibility(of node: RenderNode) -> Visibility {
        switch node.kind {
        case .text:
            return (node.text?.isEmpty == false, false)
        case .label:
            // Rendering supplies `circle` when the symbol is absent.
            return (true, false)
        case .button, .menu, .section:
            return (node.text?.isEmpty == false, false)
        case .image:
            // Rendering supplies `questionmark.square.dashed` when the symbol
            // is absent.
            return (true, false)
        case .divider,
            .rectangle,
            .roundedRectangle,
            .capsule,
            .circle,
            .ellipse,
            .unevenRoundedRectangle,
            .progressView:
            return shapeOrPrimitiveVisibility(of: node)
        case .linearGradient,
            .radialGradient,
            .angularGradient:
            return (
                false,
                styleResolver.gradient(node.colors).isVisible
            )
        case .gauge:
            return (node.value != nil, false)
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

    /// Resolves visibility for primitives and concrete shape rendering.
    private func shapeOrPrimitiveVisibility(
        of node: RenderNode
    ) -> Visibility {
        guard node.kind.isValidationShape else {
            return (true, false)
        }
        let renderedModifiers = node.modifiers.compactMap {
            $0.normalizedRenderedEffect(
                on: node.kind,
                using: styleResolver
            )
        }
        if let trim = renderedModifiers.first(where: {
            $0.renderedKind == .trim
        }),
            let from = trim.value("from")
                .flatMap(styleResolver.cleanToken)
                .flatMap(Double.init),
            let to = trim.value("to")
                .flatMap(styleResolver.cleanToken)
                .flatMap(Double.init),
            to <= from
        {
            return (false, false)
        }
        guard
            let stroke = renderedModifiers.first(where: {
                $0.renderedKind == .stroke
                    || $0.renderedKind == .strokeBorder
            })
        else {
            return (true, false)
        }
        let resolvedColor = styleResolver.color(stroke.firstValue)
        let width =
            stroke.value("lineWidth")
            .flatMap(styleResolver.cleanToken)
            .flatMap(Double.init)
            ?? 1
        return (
            false,
            width > 0
                && (resolvedColor == nil
                    || styleResolver.colorIsVisible(stroke.firstValue))
        )
    }

    /// Compares node payload fields whose children are traversed separately.
    private func hasSameNonChildContent(
        _ left: RenderNode,
        as right: RenderNode
    ) -> Bool {
        left.kind == right.kind
            && left.text == right.text
            && left.systemName == right.systemName
            && left.spacing == right.spacing
            && left.cornerRadius == right.cornerRadius
            && left.value == right.value
            && left.colors == right.colors
            && left.points == right.points
            && left.action == right.action
            && left.reorder == right.reorder
    }

    /// Enqueues matching child pairs while preserving the traversal bound.
    private func enqueueNodePairs(
        _ leftNodes: [RenderNode],
        _ rightNodes: [RenderNode],
        onto pending: inout [(RenderNode, RenderNode)],
        inspectedCount: Int
    ) -> Bool {
        guard leftNodes.count == rightNodes.count,
            leftNodes.count
                <= traversalLimit - inspectedCount - pending.count
        else {
            return false
        }
        for (left, right) in zip(leftNodes, rightNodes) {
            pending.append((left, right))
        }
        return true
    }
}

extension RenderModifier {
    /// Whether validation must inspect this modifier's rendered children.
    fileprivate var hasValidationOutputChildren: Bool {
        switch renderedKind {
        case .background, .overlay, .safeAreaInset, .mask:
            return true
        default:
            return false
        }
    }
}

extension RenderNode.Kind {
    /// Whether this kind uses the renderer's shape-specific visibility rules.
    fileprivate var isValidationShape: Bool {
        switch self {
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
}
