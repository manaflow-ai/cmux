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
    /// children like a row's close button, entirely host-side. Package
    /// visibility so reorder-lab can force it (tracking areas ignore
    /// synthesized events, so hover is otherwise undrivable in the lab).
    package var sceneHovered: Bool {
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
            ZStack(alignment: dslAlignment(node.string("alignment"))) { children }
        case "lazyVStack":
            LazyVStack(alignment: dslHAlignment(node.string("alignment") ?? "leading"), spacing: spacing) { children }
        case "group":
            children
        case "text":
            if node.props["marquee"] != nil {
                SceneMarqueeText(
                    text: node.string("text") ?? "",
                    delay: node.double("marquee") ?? 0.5
                )
            } else {
                Text(node.string("text") ?? "")
            }
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
            .modifier(SceneTrailingFade(node: node))
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
                    let flags = NSEvent.modifierFlags
                    let hasModifiers = !flags.intersection([.command, .shift, .option]).isEmpty
                    if tappable {
                        sink.send(node.id, "tap", [
                            "cmd": flags.contains(.command),
                            "shift": flags.contains(.shift),
                            "option": flags.contains(.option),
                        ])
                    }
                    // Modifier clicks (multi-select) never arm or fire the
                    // derived double-click.
                    if doubleTappable, !hasModifiers {
                        if let last = lastTapAt, now.timeIntervalSince(last) < NSEvent.doubleClickInterval {
                            lastTapAt = nil
                            sink.send(node.id, "doubletap", [:])
                            return
                        }
                    }
                    lastTapAt = hasModifiers ? nil : now
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
        field.font = .systemFont(
            ofSize: CGFloat(node.props["font"]?.doubleValue ?? 13),
            weight: Self.nsWeight(node.string("weight"))
        )
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

    private static func nsWeight(_ token: String?) -> NSFont.Weight {
        switch token {
        case "bold": return .bold
        case "semibold": return .semibold
        case "medium": return .medium
        case "light": return .light
        case "heavy": return .heavy
        default: return .regular
        }
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
    @Environment(\.sceneStore) private var store

    func body(content: Content) -> some View {
        // Mid-drag, only the dragged row may show its hover wash - and the
        // dragged row ALWAYS shows it: tracking areas lapse while the mouse
        // is down, so its own hover state can't be trusted mid-drag. The
        // wash appears at lift and holds until the drag lets go.
        let hoverAllowed = draggedNodeId == nil || draggedNodeId == node.id
        let forcedHover = draggedNodeId == node.id
        let backgroundToken = (forcedHover || (isHovered && hoverAllowed))
            ? (node.string("hoverBackground") ?? node.string("background"))
            : node.string("background")
        // Rotation applies to the raw content INSIDE the padded box (a
        // turning chevron spins in place; its layout box never moves) and
        // animates with the accordion's critically damped spring so a
        // chevron turn and a group collapse read as one motion.
        let rotation = node.double("rotation")
        let rotated = Group {
            if let rotation {
                content
                    .rotationEffect(.degrees(rotation))
                    .animation(.spring(response: 0.26, dampingFraction: 1.0), value: rotation)
            } else {
                content
            }
        }
        let padded = rotated.padding(paddingInsets)
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
            .opacity((node.double("opacity") ?? 1) * fellowDragDim)
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
                    value = forcedHover || (isHovered && hoverAllowed)
                }
            }
    }

    /// Rows sharing the dragged row's `dragSet` (a multi-selection being
    /// dragged) dim to signal they move too; everything else stays put.
    private var fellowDragDim: Double {
        guard let draggedNodeId, draggedNodeId != node.id,
              let mySet = node.string("dragSet"),
              store?.node(draggedNodeId)?.string("dragSet") == mySet else { return 1 }
        return 0.45
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

/// `.fadeOnHover(width)`: while the hover-tracking ancestor is hovered, the
/// content's trailing edge fades to transparent over the last `width` points.
/// This lets a floating close button sit OVER full-width row content (the
/// text dissolves under it) instead of reserving a permanent layout slot.
private struct SceneTrailingFade: ViewModifier {
    let node: SceneNode

    func body(content: Content) -> some View {
        if let width = node.double("fade") {
            // CONSTANT trailing fade, deliberately not hover-gated and not
            // animated: it replaces trailing padding (content dissolves where
            // accessories float), and a static mask never re-renders the row
            // mid-hover - an animated one churned tracking areas enough to
            // flicker sceneHovered and kept cancelling the marquee delay.
            content.mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: CGFloat(width))
                }
            }
        } else {
            content
        }
    }
}

/// `.marquee(delay?)` text: renders exactly like a plain truncating title at
/// rest. When the hover-tracking ancestor stays hovered for `delay` seconds
/// (default 0.5) AND the text actually overflows its slot, the full text
/// scrolls horizontally (linear, out and back) until the hover ends.
///
/// The truncating text OWNS layout the whole time - the scrolling clone
/// overlays it inside the same clipped bounds - so activating the marquee
/// never changes row geometry. The delay runs through a cancellable
/// `.task(id:)` sleep: un-hovering cancels it, per the no-asyncAfter rule.
private struct SceneMarqueeText: View {
    let text: String
    let delay: Double
    @Environment(\.sceneHovered) private var hovered
    @State private var visibleWidth: CGFloat = 0
    @State private var fullWidth: CGFloat = 0
    /// Debounced hover: enter is immediate; an exit only counts if it
    /// SURVIVES 0.4s. The marquee's own animation frames make the row's
    /// tracking area flicker (exit+re-enter within a frame or two), which
    /// used to stop the scroll and re-arm it in a visible loop. A flicker's
    /// re-enter now cancels the pending exit and the arm timer keeps its
    /// elapsed time, because its task id (stableHovered) never changed.
    @State private var stableHovered = false
    @State private var scrolling = false
    @State private var phase: CGFloat = 0

    private var overflow: CGFloat { max(0, fullWidth - visibleWidth) }

    var body: some View {
        Text(text)
            .opacity(scrolling && overflow > 1 ? 0 : 1)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { visibleWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in visibleWidth = w }
                }
            )
            .overlay(alignment: .leading) {
                if scrolling {
                    Text(text)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { fullWidth = geo.size.width }
                                    .onChange(of: geo.size.width) { _, w in fullWidth = w }
                            }
                        )
                        .offset(x: -phase * overflow)
                        .opacity(overflow > 1 ? 1 : 0)
                }
            }
            // Plain clip, no fade masks: fades popping in with the scroll
            // read as a glitch, and the mask churn re-rendered the row.
            .clipped()
            .task(id: hovered) {
                if hovered {
                    stableHovered = true
                } else {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    stableHovered = false
                }
            }
            .task(id: stableHovered) {
                guard stableHovered else {
                    settleBack()
                    return
                }
                guard !scrolling else { return }
                marqueeLog("hover start, waiting \(delay)s")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                marqueeLog("delay elapsed, scrolling on")
                scrolling = true
            }
            .onChange(of: scrolling) { _, _ in updateScrollAnimation() }
            .onChange(of: overflow) { _, _ in updateScrollAnimation() }
    }

    /// ~30pt/s out-and-back. Runs only once the clone has been measured
    /// (overflow known) - until then it must WAIT, not stop: when
    /// `scrolling` first flips on, the clone has not rendered yet and
    /// overflow is still 0 for one frame. (Calling a stop here killed the
    /// marquee the same frame it started.)
    private func updateScrollAnimation() {
        guard scrolling, overflow > 1 else { return }
        let duration = max(0.5, Double(overflow) / 30.0)
        marqueeLog("animating overflow=\(overflow) duration=\(duration)")
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: true)) {
            phase = 1
        }
    }

    /// Mouse-up/leave: glide the text back to its resting position, THEN
    /// swap the truncated layout text back in (at phase 0 they are pixel
    /// identical, so the swap is invisible). A hard phase reset here read
    /// as the text teleporting.
    private func settleBack() {
        guard scrolling else { return }
        marqueeLog("settling back")
        withAnimation(.easeOut(duration: 0.25)) {
            phase = 0
        } completion: {
            scrolling = false
        }
    }

    private func marqueeLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["CMUX_SIDEBAR_MARQUEE_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("marquee[\(text.prefix(12))]: \(message)\n".utf8))
    }
}
