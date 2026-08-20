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

private struct SceneHoveredKey: EnvironmentKey {
    static let defaultValue = false
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

    /// Whether the nearest hover-tracking ancestor (a node with a
    /// hoverBackground) is hovered. Drives `.showOnHover()`/`.hideOnHover()`
    /// children like a row's close button, entirely host-side.
    var sceneHovered: Bool {
        get { self[SceneHoveredKey.self] }
        set { self[SceneHoveredKey.self] = newValue }
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
    @Environment(\.sceneHovered) private var ancestorHovered
    @State private var lastTapAt: Date?

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
        case "textfield":
            SceneTextFieldView(node: node, sink: sink)
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
        // Hover-revealed children (a row's close button): present only while
        // the hover-tracking ancestor is hovered. Opacity keeps layout stable.
        let hoverVisible = !(node.bool("showOnHover") && !ancestorHovered)
            && !(node.bool("hideOnHover") && ancestorHovered)
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
            .opacity(hoverVisible ? 1 : 0)
            .allowsHitTesting(hoverVisible)
        let doubleTappable = node.bool("doubleTappable")
        let tappable = node.bool("tappable")
        if doubleTappable || tappable {
            base
                .contentShape(Rectangle())
                // One plain tap recognizer, zero latency: a count:2 recognizer
                // (even simultaneous) makes SwiftUI hold single taps for the
                // double-click disambiguation window, which reads as lag.
                // Double-click is DERIVED instead: two taps within the
                // system double-click interval fire the doubletap in addition
                // to their taps (tap actions like selection are idempotent,
                // so rename composes on top). Nested taps keep their native
                // child-first exclusivity.
                .onTapGesture {
                    let now = Date()
                    if tappable { sink.send(node.id, "tap", [:]) }
                    if doubleTappable {
                        if let last = lastTapAt, now.timeIntervalSince(last) < NSEvent.doubleClickInterval {
                            lastTapAt = nil
                            sink.send(node.id, "doubletap", [:])
                            return
                        }
                    }
                    lastTapAt = now
                }
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

/// Editable one-line text field backed by NSTextField: grabs first responder
/// and selects all its text the moment it mounts (type-over ready), Return
/// submits, Escape cancels, and losing focus any other way (clicking outside)
/// commits like Return. SwiftUI's TextField cannot express select-all or
/// blur-commit, which is exactly the rename UX.
private struct SceneTextFieldView: NSViewRepresentable {
    let node: SceneNode
    let sink: SceneEventSink

    func makeCoordinator() -> Coordinator {
        Coordinator(nodeId: node.id, sink: sink)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: node.string("text") ?? "")
        field.placeholderString = node.string("placeholder")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: CGFloat(node.props["font"]?.doubleValue ?? 13))
        field.delegate = context.coordinator
        // First responder can only be claimed once the field is in a window;
        // hop one runloop turn (plain async, not a timed delay).
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.placeholderString = node.string("placeholder")
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let nodeId: String
        private let sink: SceneEventSink
        private var finished = false

        init(nodeId: String, sink: SceneEventSink) {
            self.nodeId = nodeId
            self.sink = sink
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finished = true
                sink.send(nodeId, "cancel", [:])
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            // Return AND focus loss (clicking outside) both land here; both
            // commit. Escape set `finished` above and must not also submit.
            guard !finished, let field = notification.object as? NSTextField else { return }
            finished = true
            sink.send(nodeId, "submit", ["text": field.stringValue])
        }
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
            .transformEnvironment(\.sceneHovered) { value in
                // Publish hover to descendants only from tracking nodes, so a
                // non-tracking child doesn't reset an ancestor's state.
                if node.props["hoverBackground"] != nil {
                    value = isHovered && hoverAllowed
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
