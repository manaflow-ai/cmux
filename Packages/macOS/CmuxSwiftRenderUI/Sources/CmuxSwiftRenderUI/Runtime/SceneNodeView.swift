import SwiftUI

/// Sends a scene UI event (tap, move) back to the JS runtime.
struct SceneEventSink {
    let send: @MainActor (_ nodeId: String, _ event: String, _ payload: [String: Any]) -> Void
    static let noop = SceneEventSink { _, _, _ in }
}

private struct SceneStoreKey: EnvironmentKey {
    static let defaultValue: SceneStore? = nil
}

private struct SceneEventSinkKey: EnvironmentKey {
    static let defaultValue = SceneEventSink.noop
}

private struct SceneDraggedNodeKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var sceneStore: SceneStore? {
        get { self[SceneStoreKey.self] }
        set { self[SceneStoreKey.self] = newValue }
    }

    var sceneEventSink: SceneEventSink {
        get { self[SceneEventSinkKey.self] }
        set { self[SceneEventSinkKey.self] = newValue }
    }

    /// The scene node id being drag-reordered, if any. While set, hover
    /// washes are suppressed on every node except the dragged one, so rows
    /// the pointer sweeps across mid-drag don't light up.
    var sceneDraggedNodeId: String? {
        get { self[SceneDraggedNodeKey.self] }
        set { self[SceneDraggedNodeKey.self] = newValue }
    }
}

/// Renders one retained ``SceneNode`` by id.
///
/// Identity is the node id (stable across re-renders and reorders), and the
/// content view reads exactly one `@Observable` node, so a prop update on one
/// node invalidates one view. This is the fine-grained complement to the JS
/// runtime's per-prop update ops.
struct SceneNodeView: View {
    let nodeId: String
    @Environment(\.sceneStore) private var store

    var body: some View {
        if let node = store?.node(nodeId) {
            SceneNodeContent(node: node)
        }
    }
}

private struct SceneNodeContent: View {
    let node: SceneNode
    @Environment(\.sceneStore) private var store
    @Environment(\.sceneEventSink) private var sink

    var body: some View {
        // A child of type "contextMenu" is the node's right-click menu, not
        // inline content; everything else renders in place.
        if let menuId = contextMenuChildId {
            styled(content)
                .contextMenu {
                    SceneNodeView(nodeId: menuId)
                }
        } else {
            styled(content)
        }
    }

    private var contextMenuChildId: String? {
        node.children.first { store?.node($0)?.type == "contextMenu" }
    }

    @ViewBuilder
    private var content: some View {
        switch node.type {
        case "vstack":
            VStack(alignment: dslHAlignment(node.string("alignment") ?? "leading"), spacing: spacing) { children }
        case "hstack":
            HStack(alignment: dslVAlignment(node.string("alignment")), spacing: spacing) { children }
        case "zstack":
            ZStack { children }
        case "lazyVStack":
            LazyVStack(alignment: dslHAlignment(node.string("alignment") ?? "leading"), spacing: spacing) { children }
        case "group":
            children
        case "text":
            Text(node.string("text") ?? "")
        case "image":
            Image(systemName: node.string("systemName") ?? "questionmark.square.dashed")
        case "button":
            if node.children.isEmpty {
                Button(node.string("text") ?? "", role: node.bool("destructive") ? .destructive : nil) {
                    sink.send(node.id, "tap", [:])
                }
            } else {
                Button {
                    sink.send(node.id, "tap", [:])
                } label: {
                    VStack(alignment: .leading, spacing: 0) { children }
                }
                .buttonStyle(.plain)
            }
        case "spacer":
            Spacer(minLength: node.double("minLength").map { CGFloat($0) })
        case "divider":
            Divider()
        case "circle":
            shape(Circle())
        case "capsule":
            shape(Capsule())
        case "rectangle":
            shape(Rectangle())
        case "roundedRectangle":
            shape(RoundedRectangle(cornerRadius: CGFloat(node.double("cornerRadius") ?? 6)))
        case "progress":
            if let value = node.double("value") {
                ProgressView(value: min(max(value, 0), 1)) {
                    if let text = node.string("text") { Text(text) }
                }
            } else {
                ProgressView()
            }
        case "contextMenu":
            children
        case "reorderable":
            ReorderableColumnView(node: node)
        default:
            EmptyView()
        }
    }

    private var spacing: CGFloat? {
        node.double("spacing").map { CGFloat($0) }
    }

    @ViewBuilder
    private var children: some View {
        // contextMenu children never render inline (see body).
        ForEach(node.children.filter { store?.node($0)?.type != "contextMenu" }, id: \.self) { childId in
            SceneNodeView(nodeId: childId)
        }
    }

    /// Shapes fill with `fill`/`color`, optionally stroke on top (both can be
    /// set at once), and size via `size` (square) or the generic frame props.
    @ViewBuilder
    private func shape(_ base: some Shape) -> some View {
        let fill = dslColor(node.string("fill") ?? node.string("color")) ?? .secondary
        let stroke = dslColor(node.string("stroke"))
        base.fill(fill)
            .overlay {
                if let stroke {
                    base.stroke(stroke, lineWidth: CGFloat(node.double("strokeWidth") ?? 1))
                }
            }
            .frame(
                width: node.double("size").map { CGFloat($0) },
                height: node.double("size").map { CGFloat($0) }
            )
    }

    /// Applies the node's style props in one fixed, documented order:
    /// font → color → lineLimit/truncation → padding → background →
    /// cornerRadius → border → frame → opacity → tap.
    @ViewBuilder
    private func styled(_ view: some View) -> some View {
        let base = view
            .modifier(OptionalDSLFont(spec: fontSpec))
            .modifier(SceneTextStyle(node: node))
            .modifier(OptionalForeground(color: resolvedColor))
            .modifier(SceneTextLimits(node: node))
            .modifier(SceneBoxStyle(node: node))
            // A truncating Text and a Spacer are both "flexible" to HStack
            // layout, which would split the width between them and truncate
            // the text at half the row. Truncating text therefore outranks
            // spacers by default; `.layoutPriority(n)` overrides.
            .layoutPriority(
                node.double("layoutPriority")
                    ?? (node.type == "text" && node.props["lineLimit"] != nil ? 1 : 0)
            )
        if node.bool("tappable") {
            base
                .contentShape(Rectangle())
                .onTapGesture { sink.send(node.id, "tap", [:]) }
        } else {
            base
        }
    }

    private var resolvedColor: Color? {
        if node.bool("secondary") { return .secondary }
        return dslColor(node.string("color"))
    }

    private var fontSpec: DSLFontSpec? {
        let weight = dslFontWeight(node.string("weight"))
        if let size = node.props["font"]?.doubleValue {
            return dslFontSpec(named: nil, size: size, weight: weight)
        }
        if let named = node.string("font") {
            return dslFontSpec(named: named, size: nil, weight: weight)
        }
        if weight != nil {
            return dslFontSpec(named: "body", size: nil, weight: weight)
        }
        return nil
    }
}

/// Bold/italic/monospaced toggles for text nodes.
private struct SceneTextStyle: ViewModifier {
    let node: SceneNode

    func body(content: Content) -> some View {
        content
            .fontWeight(node.bool("bold") ? .bold : nil)
            .italic(node.bool("italic"))
            .monospaced(node.bool("monospaced"))
    }
}

/// Line-limit and truncation for text nodes.
private struct SceneTextLimits: ViewModifier {
    let node: SceneNode

    func body(content: Content) -> some View {
        content
            .lineLimit(node.double("lineLimit").map { Int($0) })
            .truncationMode(dslTruncationMode(node.string("truncation")))
    }
}

/// Resolves a material background token: `glass`/`ultraThinMaterial`,
/// `thinMaterial`, `regularMaterial`, `thickMaterial`. These blur whatever is
/// behind the view in the window, which is what makes a translucent "liquid
/// glass" surface possible.
func sceneMaterial(_ token: String?) -> Material? {
    switch token {
    case "glass", "ultraThinMaterial": return .ultraThinMaterial
    case "thinMaterial": return .thinMaterial
    case "regularMaterial", "material": return .regularMaterial
    case "thickMaterial": return .thickMaterial
    default: return nil
    }
}

/// Padding, background (with hover), corner radius, border, frame, opacity —
/// the box styling half of the fixed modifier order.
///
/// All rounding uses `.continuous` corner curvature (the squircle), matching
/// modern macOS chrome. `hoverBackground` is a host-side visual: the hover
/// state never round-trips through the JS runtime, so it is latency-free and
/// costs nothing when the prop is absent.
private struct SceneBoxStyle: ViewModifier {
    let node: SceneNode
    @State private var isHovered = false
    @Environment(\.sceneDraggedNodeId) private var draggedNodeId

    func body(content: Content) -> some View {
        // Mid-drag, only the dragged row may show its hover wash.
        let hoverAllowed = draggedNodeId == nil || draggedNodeId == node.id
        let backgroundToken = (isHovered && hoverAllowed)
            ? (node.string("hoverBackground") ?? node.string("background"))
            : node.string("background")
        let padded = content.padding(paddingInsets)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let backed = Group {
            if let material = sceneMaterial(backgroundToken) {
                padded.background(material, in: shape)
            } else if let background = dslColor(backgroundToken) {
                padded.background(background, in: shape)
            } else if cornerRadius > 0 {
                padded.clipShape(shape)
            } else {
                padded
            }
        }
        let bordered = Group {
            if let borderColor = dslColor(node.string("borderColor")) {
                backed.overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: CGFloat(node.double("borderWidth") ?? 1))
                )
            } else {
                backed
            }
        }
        return bordered
            .frame(
                minWidth: dimension("minWidth"),
                maxWidth: dimension("maxWidth"),
                minHeight: dimension("minHeight"),
                maxHeight: dimension("maxHeight"),
                alignment: .leading
            )
            .frame(width: dimension("width"), height: dimension("height"))
            .opacity(node.double("opacity") ?? 1)
            // Outer margin: an inset OUTSIDE the background box. This is how
            // nesting indent is expressed (the box narrows from the left,
            // right edge fixed), as opposed to paddingLeading, which indents
            // content INSIDE a full-width box.
            .padding(.leading, CGFloat(node.double("marginLeading") ?? 0))
            .onHover { hovering in
                guard node.props["hoverBackground"] != nil else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
    }

    private var cornerRadius: CGFloat {
        CGFloat(node.double("cornerRadius") ?? 0)
    }

    private var paddingInsets: EdgeInsets {
        let all = node.double("padding") ?? 0
        let horizontal = node.double("paddingHorizontal") ?? all
        let vertical = node.double("paddingVertical") ?? all
        return EdgeInsets(
            top: node.double("paddingTop") ?? vertical,
            leading: node.double("paddingLeading") ?? horizontal,
            bottom: node.double("paddingBottom") ?? vertical,
            trailing: node.double("paddingTrailing") ?? horizontal
        )
    }

    private func dimension(_ key: String) -> CGFloat? {
        guard let prop = node.props[key] else { return nil }
        if prop.stringValue == "infinity" { return .infinity }
        return prop.doubleValue.map { CGFloat($0) }
    }
}
