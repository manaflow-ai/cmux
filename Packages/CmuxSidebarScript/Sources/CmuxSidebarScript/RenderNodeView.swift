import SwiftUI

/// Renders a `RenderNode` tree as SwiftUI. This is the only SwiftUI-aware part
/// of the engine; everything upstream is pure, `Equatable` data.
public struct RenderNodeView: View {
    public let node: RenderNode
    /// Host handler for tap targets (`open-url`, `copy-text`, ...). Optional so
    /// the engine and previews work without a host.
    public var onAction: ((RNAction) -> Void)?

    public init(node: RenderNode, onAction: ((RNAction) -> Void)? = nil) {
        self.node = node
        self.onAction = onAction
    }

    public var body: some View {
        RenderNodeRenderer(onAction: onAction).view(for: node)
    }
}

/// Stateless converter from `RenderNode` to `AnyView`. `AnyView` is used because
/// the node tree is dynamic; the `.equatable()` guard on the row (over the node)
/// keeps SwiftUI from rebuilding untouched rows, so the type erasure here costs
/// only the rows that actually change.
struct RenderNodeRenderer {
    let onAction: ((RNAction) -> Void)?

    func view(for node: RenderNode) -> AnyView {
        let base = baseView(for: node)
        return applyModifiers(base, node.modifiers)
    }

    @ViewBuilder
    private func children(_ nodes: [RenderNode]) -> some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { _, child in
            view(for: child)
        }
    }

    // MARK: - Base views

    private func baseView(for node: RenderNode) -> AnyView {
        switch node.kind {
        case "vstack":
            return AnyView(VStack(
                alignment: horizontal(node.content["alignment"]) ?? .leading,
                spacing: node.content["spacing"]?.number.map { CGFloat($0) }
            ) { children(node.children) })
        case "hstack":
            return AnyView(HStack(
                alignment: vertical(node.content["alignment"]) ?? .center,
                spacing: node.content["spacing"]?.number.map { CGFloat($0) }
            ) { children(node.children) })
        case "zstack":
            return AnyView(ZStack(
                alignment: alignment2D(node.content["alignment"]) ?? .center
            ) { children(node.children) })
        case "group":
            return AnyView(Group { children(node.children) })
        case "text":
            return AnyView(Text(node.content["text"]?.string ?? ""))
        case "image":
            if let sys = node.content["system"]?.string {
                return AnyView(Image(systemName: sys))
            } else if let name = node.content["name"]?.string {
                return AnyView(Image(name))
            }
            return AnyView(EmptyView())
        case "label":
            let title = node.content["text"]?.string ?? ""
            if let sys = node.content["system"]?.string {
                return AnyView(Label(title, systemImage: sys))
            }
            return AnyView(Text(title))
        case "spacer":
            return AnyView(Spacer(minLength: node.content["min"]?.number.map { CGFloat($0) }))
        case "divider":
            return AnyView(Divider())
        case "rectangle":
            return shapeView(Rectangle(), node)
        case "capsule":
            return shapeView(Capsule(), node)
        case "circle":
            return shapeView(Circle(), node)
        case "rounded-rectangle":
            let r = node.content["radius"]?.number ?? 6
            return shapeView(RoundedRectangle(cornerRadius: CGFloat(r), style: .continuous), node)
        case "progress-view":
            if let value = node.content["value"]?.number {
                let total = node.content["total"]?.number ?? 1
                return AnyView(ProgressView(value: value, total: total).progressViewStyle(.linear))
            }
            return AnyView(ProgressView())
        case "button":
            let action = node.content["action"]?.actionValue
            return AnyView(Button {
                if let action { onAction?(action) }
            } label: {
                VStack(alignment: .leading, spacing: 0) { children(node.children) }
            }.buttonStyle(.plain))
        case "empty":
            return AnyView(EmptyView())
        default:
            return AnyView(EmptyView())
        }
    }

    private func shapeView<S: Shape>(_ shape: S, _ node: RenderNode) -> AnyView {
        let filled: AnyView
        if let fill = node.content["fill"] {
            filled = AnyView(shape.fill(shapeStyle(fill)))
        } else if node.content["stroke"] != nil {
            filled = AnyView(shape.fill(Color.clear))
        } else {
            filled = AnyView(shape.fill(Color.primary))
        }
        guard case .color(let strokeColor)? = node.content["stroke"] else { return filled }
        let width = node.content["stroke-width"]?.number ?? 1
        return AnyView(filled.overlay(shape.stroke(color(strokeColor), lineWidth: CGFloat(width))))
    }

    // MARK: - Modifiers

    private func applyModifiers(_ view: AnyView, _ mods: [RenderModifier]) -> AnyView {
        var v = view
        for m in mods { v = apply(m, to: v) }
        return v
    }

    private func apply(_ m: RenderModifier, to view: AnyView) -> AnyView {
        switch m.name {
        case "padding":
            if case .edges(let e)? = m.first { return AnyView(view.padding(insets(e))) }
            return view
        case "frame":
            return frame(view, m.named)
        case "border":
            return border(view, m.named)
        case "foreground":
            return foreground(view, m.first)
        case "background":
            return background(view, m.first)
        case "tint":
            if case .color(let c)? = m.first { return AnyView(view.tint(color(c))) }
            return view
        case "font":
            if case .font(let f)? = m.first { return AnyView(view.font(font(f))) }
            return view
        case "corner-radius":
            let r = m.first?.number ?? 0
            return AnyView(view.clipShape(RoundedRectangle(cornerRadius: CGFloat(r), style: .continuous)))
        case "opacity":
            return AnyView(view.opacity(m.first?.number ?? 1))
        case "blur":
            return AnyView(view.blur(radius: CGFloat(m.first?.number ?? 0)))
        case "rotation":
            return AnyView(view.rotationEffect(.degrees(m.first?.number ?? 0)))
        case "line-limit":
            return AnyView(view.lineLimit(Int(m.first?.number ?? 1)))
        case "kerning":
            return AnyView(view.kerning(CGFloat(m.first?.number ?? 0)))
        case "layout-priority":
            return AnyView(view.layoutPriority(m.first?.number ?? 0))
        case "z-index":
            return AnyView(view.zIndex(m.first?.number ?? 0))
        case "truncation":
            return AnyView(view.truncationMode(truncationMode(m.first?.string)))
        case "text-align":
            if case .alignment(let a)? = m.first { return AnyView(view.multilineTextAlignment(textAlignment(a))) }
            return view
        case "shadow":
            if case .shadow(let s)? = m.first {
                return AnyView(view.shadow(color: color(s.color), radius: CGFloat(s.radius),
                                           x: CGFloat(s.x), y: CGFloat(s.y)))
            }
            return view
        case "overlay":
            if case .node(let n)? = m.first { return AnyView(view.overlay { self.view(for: n) }) }
            return view
        case "offset":
            if case .list(let xy)? = m.first, xy.count == 2 {
                return AnyView(view.offset(x: CGFloat(xy[0].number ?? 0), y: CGFloat(xy[1].number ?? 0)))
            }
            return view
        case "bold":
            return boolOn(m) ? AnyView(view.bold()) : view
        case "italic":
            return boolOn(m) ? AnyView(view.italic()) : view
        case "underline":
            return AnyView(view.underline(boolOn(m)))
        case "strikethrough":
            return AnyView(view.strikethrough(boolOn(m)))
        case "monospaced-digit":
            return boolOn(m) ? AnyView(view.monospacedDigit()) : view
        case "fixed-size":
            return boolOn(m) ? AnyView(view.fixedSize()) : view
        case "clip":
            return boolOn(m) ? AnyView(view.clipped()) : view
        case "disabled":
            return AnyView(view.disabled(boolOn(m)))
        case "help":
            return AnyView(view.help(m.first?.string ?? ""))
        case "on-tap":
            if case .action(let a)? = m.first {
                return AnyView(view.contentShape(Rectangle()).onTapGesture { onAction?(a) })
            }
            return view
        default:
            return view
        }
    }

    private func boolOn(_ m: RenderModifier) -> Bool {
        if case .bool(let b)? = m.first { return b }
        return true
    }

    private func frame(_ view: AnyView, _ named: [String: RNValue]) -> AnyView {
        let align = (named["frame-align"].flatMap { v -> RNAlignment? in
            if case .alignment(let a) = v { return a }; return nil
        }).map(alignment) ?? .center
        let w = named["width"]?.number
        let h = named["height"]?.number
        if w != nil || h != nil {
            return AnyView(view.frame(
                width: w.map { CGFloat($0) },
                height: h.map { CGFloat($0) },
                alignment: align))
        }
        return AnyView(view.frame(
            minWidth: named["min-width"]?.number.map { CGFloat($0) },
            maxWidth: named["max-width"]?.number.map { CGFloat($0) },
            minHeight: named["min-height"]?.number.map { CGFloat($0) },
            maxHeight: named["max-height"]?.number.map { CGFloat($0) },
            alignment: align))
    }

    private func border(_ view: AnyView, _ named: [String: RNValue]) -> AnyView {
        guard case .color(let c)? = named["border"] else { return view }
        let width = named["border-width"]?.number ?? 1
        return AnyView(view.border(color(c), width: CGFloat(width)))
    }

    private func foreground(_ view: AnyView, _ value: RNValue?) -> AnyView {
        switch value {
        case .color(let c)?: return AnyView(view.foregroundStyle(color(c)))
        case .gradient(let g)?: return AnyView(view.foregroundStyle(gradient(g)))
        default: return view
        }
    }

    private func background(_ view: AnyView, _ value: RNValue?) -> AnyView {
        switch value {
        case .color(let c)?: return AnyView(view.background(color(c)))
        case .gradient(let g)?: return AnyView(view.background(gradient(g)))
        case .node(let n)?: return AnyView(view.background { self.view(for: n) })
        default: return view
        }
    }

    private func shapeStyle(_ value: RNValue) -> AnyShapeStyle {
        switch value {
        case .color(let c): return AnyShapeStyle(color(c))
        case .gradient(let g): return AnyShapeStyle(gradient(g))
        default: return AnyShapeStyle(Color.primary)
        }
    }

    // MARK: - Conversions

    private func color(_ c: RNColor) -> Color {
        switch c {
        case .hex(let s): return Color(hex: s) ?? .clear
        case .rgba(let r, let g, let b, let a):
            let (rr, gg, bb) = normalizeRGB(r, g, b)
            return Color(.sRGB, red: rr, green: gg, blue: bb, opacity: a)
        case .semantic(let name): return semanticColor(name)
        case .named(let name): return namedColor(name)
        }
    }

    private func normalizeRGB(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        if r > 1 || g > 1 || b > 1 { return (r / 255, g / 255, b / 255) }
        return (r, g, b)
    }

    private func semanticColor(_ name: String) -> Color {
        switch name {
        case "primary", "label": return .primary
        case "secondary": return .secondary
        case "accent", "tint": return .accentColor
        case "clear": return .clear
        default: return .primary
        }
    }

    private func namedColor(_ name: String) -> Color {
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        case "gray", "grey": return .gray
        case "black": return .black
        case "white": return .white
        default: return Color(name) // asset catalog fallback
        }
    }

    private func gradient(_ g: RNGradient) -> LinearGradient {
        let colors = g.colors.map(color)
        let (start, end): (UnitPoint, UnitPoint)
        switch g.direction {
        case .vertical: (start, end) = (.top, .bottom)
        case .horizontal: (start, end) = (.leading, .trailing)
        case .diagonal: (start, end) = (.topLeading, .bottomTrailing)
        }
        return LinearGradient(colors: colors, startPoint: start, endPoint: end)
    }

    private func font(_ f: RNFont) -> Font {
        var base: Font
        if let size = f.size {
            base = .system(size: CGFloat(size), weight: weight(f.weight), design: design(f.design))
        } else if let style = f.textStyle {
            base = textStyleFont(style)
            if let w = f.weight { base = base.weight(weight(w)) }
        } else {
            base = .body
            if let w = f.weight { base = base.weight(weight(w)) }
        }
        if f.italic { base = base.italic() }
        if f.monospacedDigit { base = base.monospacedDigit() }
        return base
    }

    private func weight(_ name: String?) -> Font.Weight {
        switch name {
        case "thin": return .thin
        case "ultralight": return .ultraLight
        case "light": return .light
        case "regular": return .regular
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        case "black": return .black
        default: return .regular
        }
    }

    private func design(_ name: String?) -> Font.Design {
        switch name {
        case "serif": return .serif
        case "rounded": return .rounded
        case "monospaced": return .monospaced
        default: return .default
        }
    }

    private func textStyleFont(_ name: String) -> Font {
        switch name {
        case "large-title": return .largeTitle
        case "title": return .title
        case "title2": return .title2
        case "title3": return .title3
        case "headline": return .headline
        case "subheadline": return .subheadline
        case "body": return .body
        case "callout": return .callout
        case "footnote": return .footnote
        case "caption": return .caption
        case "caption2": return .caption2
        default: return .body
        }
    }

    private func insets(_ e: RNEdges) -> EdgeInsets {
        EdgeInsets(top: CGFloat(e.top), leading: CGFloat(e.leading),
                   bottom: CGFloat(e.bottom), trailing: CGFloat(e.trailing))
    }

    private func horizontal(_ v: RNValue?) -> HorizontalAlignment? {
        guard case .alignment(let a)? = v else { return nil }
        switch a.raw {
        case "leading", "top-leading", "bottom-leading": return .leading
        case "trailing", "top-trailing", "bottom-trailing": return .trailing
        default: return .center
        }
    }

    private func vertical(_ v: RNValue?) -> VerticalAlignment? {
        guard case .alignment(let a)? = v else { return nil }
        switch a.raw {
        case "top", "top-leading", "top-trailing": return .top
        case "bottom", "bottom-leading", "bottom-trailing": return .bottom
        case "firstTextBaseline", "first-text-baseline": return .firstTextBaseline
        case "lastTextBaseline", "last-text-baseline": return .lastTextBaseline
        default: return .center
        }
    }

    private func alignment2D(_ v: RNValue?) -> Alignment? {
        guard case .alignment(let a)? = v else { return nil }
        return alignment(a)
    }

    private func alignment(_ a: RNAlignment) -> Alignment {
        switch a.raw {
        case "leading": return .leading
        case "trailing": return .trailing
        case "top": return .top
        case "bottom": return .bottom
        case "top-leading": return .topLeading
        case "top-trailing": return .topTrailing
        case "bottom-leading": return .bottomLeading
        case "bottom-trailing": return .bottomTrailing
        case "center": return .center
        default: return .center
        }
    }

    private func textAlignment(_ a: RNAlignment) -> TextAlignment {
        switch a.raw {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }

    private func truncationMode(_ name: String?) -> Text.TruncationMode {
        switch name {
        case "head": return .head
        case "middle": return .middle
        default: return .tail
        }
    }
}

private extension RNValue {
    var actionValue: RNAction? {
        if case .action(let a) = self { return a }
        return nil
    }
}

extension Color {
    /// Parses `#rgb`, `#rrggbb`, or `#rrggbbaa`. Returns nil on malformed input.
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch s.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
            a = 1
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            return nil
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
