import CmuxSwiftRender
import SwiftUI

/// Renders the Swift interpreter's ``RenderNode`` IR as native SwiftUI.
///
/// Modifier arguments arrive as source strings (e.g. `.title`, `.blue`, `8`)
/// and are applied best-effort; unknown modifiers are ignored. Button taps and
/// `.onTapGesture` actions are dispatched through ``sidebarActionDispatch``
/// from the environment.
struct RenderNodeView: View {
    let node: RenderNode

    @Environment(\.sidebarActionDispatch) private var dispatch

    var body: some View {
        let view = applyModifiers(content, node.modifiers)
        // A non-button node carrying an action (from `.onTapGesture`) becomes
        // tappable across its whole bounds.
        if node.kind != .button, let action = node.action {
            return AnyView(
                view.contentShape(Rectangle())
                    .onTapGesture { dispatch.run(action) }
                    .reportTapTarget(action)
            )
        }
        return view
    }

    @ViewBuilder
    private var content: some View {
        switch node.kind {
        case .vstack:
            VStack(alignment: .leading, spacing: node.spacing.map { CGFloat($0) }) { children }
        case .hstack:
            HStack(spacing: node.spacing.map { CGFloat($0) }) { children }
        case .zstack:
            ZStack { children }
        case .lazyVStack:
            LazyVStack(alignment: .leading, spacing: node.spacing.map { CGFloat($0) }) { children }
        case .lazyHStack:
            LazyHStack(spacing: node.spacing.map { CGFloat($0) }) { children }
        case .group:
            Group { children }
        case .list:
            // Plain, chrome-light list so it sits naturally in the sidebar
            // rather than imposing inset grouped-table styling.
            List { children }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
        case .section:
            VStack(alignment: .leading, spacing: 4) {
                if let header = node.text, !header.isEmpty {
                    Text(header)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                children
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .hscroll:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: node.spacing.map { CGFloat($0) }) { children }
            }
        case .grid:
            Grid(alignment: .leading, horizontalSpacing: node.spacing.map { CGFloat($0) },
                 verticalSpacing: node.spacing.map { CGFloat($0) }) { children }
        case .gridRow:
            GridRow { children }
        case .lazyVGrid:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: node.spacing.map { CGFloat($0) })],
                      spacing: node.spacing.map { CGFloat($0) }) { children }
        case .lazyHGrid:
            LazyHGrid(rows: [GridItem(.adaptive(minimum: 40), spacing: node.spacing.map { CGFloat($0) })],
                      spacing: node.spacing.map { CGFloat($0) }) { children }
        case .viewThatFits:
            ViewThatFits { children }
        case .hsplit:
            ResizableHSplit(columns: node.children)
        case .reorderable:
            ReorderableList(rows: node.children, spec: node.reorder)
        case .text:
            Text(node.text ?? "")
        case .label:
            Label(node.text ?? "", systemImage: node.systemName ?? "circle")
        case .image:
            styledImage(Image(systemName: node.systemName ?? "questionmark.square.dashed"))
        case .button:
            if node.children.isEmpty {
                Button(node.text ?? "") {
                    if let action = node.action { dispatch.run(action) }
                }
                .reportTapTarget(node.action)
            } else {
                // Rich label form: `Button(action:){ label }`. Plain style so
                // the label renders as authored, not as default button chrome.
                Button {
                    if let action = node.action { dispatch.run(action) }
                } label: {
                    VStack(alignment: .leading, spacing: 0) { children }
                }
                .buttonStyle(.plain)
                .reportTapTarget(node.action)
            }
        case .spacer:
            Spacer(minLength: node.spacing.map { CGFloat($0) })
        case .divider:
            Divider()
        case .rectangle:
            styledShape(Rectangle())
        case .roundedRectangle:
            styledShape(RoundedRectangle(cornerRadius: CGFloat(node.cornerRadius ?? 6)))
        case .capsule:
            styledShape(Capsule())
        case .circle:
            styledShape(Circle())
        case .ellipse:
            styledShape(Ellipse())
        case .unevenRoundedRectangle:
            styledShape(RoundedRectangle(cornerRadius: CGFloat(node.cornerRadius ?? 6)))
        case .progressView:
            if let value = node.value {
                ProgressView(value: value) { if let t = node.text { Text(t) } }
            } else if let t = node.text {
                ProgressView(t)
            } else {
                ProgressView()
            }
        case .gauge:
            if let value = node.value {
                Gauge(value: value) { if let t = node.text { Text(t) } }
            } else {
                EmptyView()
            }
        case .menu:
            Menu(node.text ?? "") { children }
        case .linearGradient:
            LinearGradient(colors: gradientColors(node),
                           startPoint: dslUnitPoint(node.points.first, default: .top),
                           endPoint: dslUnitPoint(node.points.count > 1 ? node.points[1] : nil, default: .bottom))
        case .radialGradient:
            RadialGradient(colors: gradientColors(node),
                           center: dslUnitPoint(node.points.first, default: .center),
                           startRadius: 0, endRadius: 90)
        case .angularGradient:
            AngularGradient(colors: gradientColors(node),
                            center: dslUnitPoint(node.points.first, default: .center))
        }
    }

    @ViewBuilder
    private var children: some View {
        ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
            RenderNodeView(node: child)
        }
    }

    private func applyModifiers(_ view: some View, _ modifiers: [RenderModifier]) -> AnyView {
        var result = AnyView(view)
        for modifier in modifiers {
            result = apply(modifier, to: result)
        }
        return result
    }

    private func apply(_ modifier: RenderModifier, to view: AnyView) -> AnyView {
        let token = clean(modifier.firstValue)
        switch modifier.name {
        case "font":
            return AnyView(view.font(resolveFont(token)))
        case "bold":
            return AnyView(view.fontWeight(.bold))
        case "strikethrough":
            return AnyView(view.strikethrough())
        case "underline":
            return AnyView(view.underline())
        case "italic":
            return AnyView(view.italic())
        case "monospaced":
            return AnyView(view.monospaced())
        case "monospacedDigit":
            return AnyView(view.monospacedDigit())
        case "fontWeight":
            return AnyView(view.fontWeight(dslFontWeight(token)))
        case "fontDesign":
            return AnyView(view.fontDesign(dslFontDesign(token)))
        case "multilineTextAlignment":
            return AnyView(view.multilineTextAlignment(dslTextAlignment(token)))
        case "textCase":
            return AnyView(view.textCase(dslTextCase(token)))
        case "truncationMode":
            return AnyView(view.truncationMode(dslTruncationMode(token)))
        case "foregroundColor", "foregroundStyle", "fill", "tint":
            if let color = dslColor(token) { return AnyView(view.foregroundStyle(color)) }
            return view
        case "padding":
            if let token, let value = Double(token) { return AnyView(view.padding(CGFloat(value))) }
            return AnyView(view.padding())
        case "background":
            if !modifier.children.isEmpty {
                let alignment = frameAlignment(clean(modifier.value("alignment")))
                return AnyView(view.background(alignment: alignment) { modifierChildren(modifier) })
            }
            if let color = dslColor(token) { return AnyView(view.background(color)) }
            return view
        case "overlay":
            if !modifier.children.isEmpty {
                let alignment = frameAlignment(clean(modifier.value("alignment")))
                return AnyView(view.overlay(alignment: alignment) { modifierChildren(modifier) })
            }
            if let color = dslColor(token) { return AnyView(view.overlay(color)) }
            return view
        case "mask":
            if !modifier.children.isEmpty {
                return AnyView(view.mask { modifierChildren(modifier) })
            }
            return view
        case "safeAreaInset":
            if !modifier.children.isEmpty {
                let edge = clean(modifier.value("edge"))
                if edge == "top" {
                    return AnyView(view.safeAreaInset(edge: .top) { modifierChildren(modifier) })
                }
                return AnyView(view.safeAreaInset(edge: .bottom) { modifierChildren(modifier) })
            }
            return view
        case "cornerRadius":
            if let token, let value = Double(token) {
                return AnyView(view.clipShape(RoundedRectangle(cornerRadius: CGFloat(value))))
            }
            return view
        case "opacity":
            if let token, let value = Double(token) { return AnyView(view.opacity(value)) }
            return view
        case "lineLimit":
            if let token, let value = Int(token) { return AnyView(view.lineLimit(value)) }
            return view
        case "frame":
            return applyFrame(modifier, to: view)
        case "shadow":
            let radius = modDouble(modifier, "radius") ?? (token.flatMap(Double.init)) ?? 4
            let color = dslColor(clean(modifier.value("color"))) ?? Color.black.opacity(0.33)
            return AnyView(view.shadow(color: color, radius: CGFloat(radius),
                                       x: CGFloat(modDouble(modifier, "x") ?? 0),
                                       y: CGFloat(modDouble(modifier, "y") ?? 0)))
        case "border":
            let color = dslColor(token) ?? .secondary
            let width = modDouble(modifier, "width") ?? 1
            return AnyView(view.border(color, width: CGFloat(width)))
        case "blur":
            let radius = modDouble(modifier, "radius") ?? (token.flatMap(Double.init)) ?? 0
            return AnyView(view.blur(radius: CGFloat(radius)))
        case "offset":
            return AnyView(view.offset(x: CGFloat(modDouble(modifier, "x") ?? 0),
                                       y: CGFloat(modDouble(modifier, "y") ?? 0)))
        case "scaleEffect":
            if let token, let s = Double(token) { return AnyView(view.scaleEffect(CGFloat(s))) }
            return view
        case "rotationEffect":
            return AnyView(view.rotationEffect(.degrees(angleDegrees(token) ?? 0)))
        case "zIndex":
            if let token, let z = Double(token) { return AnyView(view.zIndex(z)) }
            return view
        case "brightness":
            return AnyView(view.brightness(token.flatMap(Double.init) ?? 0))
        case "contrast":
            return AnyView(view.contrast(token.flatMap(Double.init) ?? 1))
        case "saturation":
            return AnyView(view.saturation(token.flatMap(Double.init) ?? 1))
        case "grayscale":
            return AnyView(view.grayscale(token.flatMap(Double.init) ?? 0))
        case "clipShape":
            return applyClipShape(token, to: view)
        case "imageScale":
            return AnyView(view.imageScale(dslImageScale(token)))
        case "symbolRenderingMode":
            return AnyView(view.symbolRenderingMode(dslSymbolRenderingMode(token)))
        case "symbolVariant":
            return AnyView(view.symbolVariant(dslSymbolVariant(token)))
        case "contextMenu":
            if !modifier.children.isEmpty {
                return AnyView(view.contextMenu { modifierChildren(modifier) })
            }
            return view
        case "help":
            if let token { return AnyView(view.help(LocalizedStringKey(token))) }
            return view
        case "keyboardShortcut":
            guard let key = dslKeyEquivalent(token) else { return view }
            return AnyView(view.keyboardShortcut(key, modifiers: dslEventModifiers(modifier.value("modifiers"))))
        case "disabled":
            // Disabled only when the arg explicitly resolves to true; an
            // unresolved expression defaults to enabled, not disabled.
            return AnyView(view.disabled(token == "true"))
        case "redacted":
            let reason = clean(modifier.value("reason")) ?? token
            return AnyView(view.redacted(reason: reason == "invalidated" ? .invalidated : .placeholder))
        case "unredacted":
            return AnyView(view.unredacted())
        case "accessibilityLabel":
            return AnyView(view.accessibilityLabel(Text(token ?? "")))
        case "accessibilityHint":
            return AnyView(view.accessibilityHint(Text(token ?? "")))
        case "accessibilityValue":
            return AnyView(view.accessibilityValue(Text(token ?? "")))
        case "accessibilityHidden":
            return AnyView(view.accessibilityHidden(token != "false"))
        case "scrollIndicators":
            return AnyView(view.scrollIndicators(token == "hidden" || token == "never" ? .hidden : .visible))
        case "scrollContentBackground":
            return AnyView(view.scrollContentBackground(token == "hidden" ? .hidden : .visible))
        case "aspectRatio":
            let mode: ContentMode = clean(modifier.value("contentMode")) == "fill" ? .fill : .fit
            // Only apply an explicit ratio when positive; a zero/negative ratio
            // is invalid in SwiftUI, so fall back to mode-only.
            if let token, let ratio = Double(token), ratio > 0 { return AnyView(view.aspectRatio(CGFloat(ratio), contentMode: mode)) }
            return AnyView(view.aspectRatio(contentMode: mode))
        case "scaledToFit":
            return AnyView(view.aspectRatio(contentMode: .fit))
        case "scaledToFill":
            return AnyView(view.aspectRatio(contentMode: .fill))
        case "clipped":
            return AnyView(view.clipped())
        case "fixedSize":
            return AnyView(view.fixedSize())
        case "layoutPriority":
            return AnyView(view.layoutPriority(token.flatMap(Double.init) ?? 0))
        default:
            return view
        }
    }

    /// Renders an image, applying `.resizable()` on the concrete `Image` before
    /// erasure (it's an `Image` method, unavailable on `AnyView`). `.scaledToFit`/
    /// `.aspectRatio` from the generic modifier pass then apply on top.
    private func styledImage(_ image: Image) -> AnyView {
        if node.modifiers.contains(where: { $0.name == "resizable" }) {
            return AnyView(image.resizable())
        }
        return AnyView(image)
    }

    /// Resolves a gradient node's color stops, falling back to two clear stops
    /// so an empty/unresolved gradient is harmless rather than invalid.
    private func gradientColors(_ node: RenderNode) -> [Color] {
        let resolved = node.colors.compactMap { dslColor($0) }
        return resolved.count >= 2 ? resolved : (resolved + [.clear, .clear])
    }

    /// Renders a shape, applying shape-level `.trim` then `.stroke` /
    /// `.strokeBorder` (which must act on the concrete `Shape` before erasure).
    /// With no stroke the plain shape is returned so `.fill`/`.foregroundColor`
    /// from the generic modifier pass fills it.
    private func styledShape(_ shape: some Shape) -> AnyView {
        var resolved = AnyShape(shape)
        if let trim = node.modifiers.first(where: { $0.name == "trim" }) {
            resolved = AnyShape(resolved.trim(from: CGFloat(modDouble(trim, "from") ?? 0),
                                              to: CGFloat(modDouble(trim, "to") ?? 1)))
        }
        if let stroke = node.modifiers.first(where: { $0.name == "stroke" || $0.name == "strokeBorder" }) {
            let color = dslColor(clean(stroke.firstValue)) ?? .secondary
            let width = modDouble(stroke, "lineWidth") ?? 1
            return AnyView(resolved.stroke(color, lineWidth: CGFloat(width)))
        }
        return AnyView(resolved)
    }

    /// Renders a child-bearing modifier's subtree (overlay/background/mask
    /// content). Multiple top-level views stack in a `ZStack`.
    @ViewBuilder
    private func modifierChildren(_ modifier: RenderModifier) -> some View {
        if modifier.children.count == 1 {
            RenderNodeView(node: modifier.children[0])
        } else {
            ZStack {
                ForEach(Array(modifier.children.enumerated()), id: \.offset) { _, child in
                    RenderNodeView(node: child)
                }
            }
        }
    }

    /// A labeled `Double` argument of a modifier (e.g. `.shadow(radius: 4)`).
    private func modDouble(_ modifier: RenderModifier, _ label: String) -> Double? {
        modifier.value(label).map { clean($0) ?? $0 }.flatMap { Double($0) }
    }

    /// Degrees from an angle token like `.degrees(45)` or `.radians(1.5)`.
    private func angleDegrees(_ token: String?) -> Double? {
        guard let token else { return nil }
        if let open = token.firstIndex(of: "("), let close = token.lastIndex(of: ")") {
            let inner = String(token[token.index(after: open)..<close])
            guard let value = Double(inner.trimmingCharacters(in: .whitespaces)) else { return nil }
            return token.contains("radians") ? value * 180 / .pi : value
        }
        return Double(token)
    }

    /// Resolves a `.clipShape(<Shape>())` token to a clip.
    private func applyClipShape(_ token: String?, to view: AnyView) -> AnyView {
        switch token.map({ $0.lowercased() }) {
        case let t? where t.hasPrefix("circle"): return AnyView(view.clipShape(Circle()))
        case let t? where t.hasPrefix("capsule"): return AnyView(view.clipShape(Capsule()))
        case let t? where t.hasPrefix("ellipse"): return AnyView(view.clipShape(Ellipse()))
        case let t? where t.hasPrefix("rectangle"): return AnyView(view.clipShape(Rectangle()))
        default: return AnyView(view.clipShape(RoundedRectangle(cornerRadius: 8)))
        }
    }

    /// Applies `.frame(width:height:minWidth:maxWidth:alignment:)` from the
    /// modifier's labeled arguments (`.infinity` supported for max bounds).
    private func applyFrame(_ modifier: RenderModifier, to view: AnyView) -> AnyView {
        func dim(_ label: String) -> CGFloat? {
            guard let raw = modifier.value(label) else { return nil }
            if raw == ".infinity" || raw == "infinity" { return .infinity }
            return Double(raw).map { CGFloat($0) }
        }
        let alignment = frameAlignment(clean(modifier.value("alignment")))
        return AnyView(
            view.frame(
                minWidth: dim("minWidth"),
                maxWidth: dim("maxWidth"),
                minHeight: dim("minHeight"),
                maxHeight: dim("maxHeight"),
                alignment: alignment
            )
            .frame(width: dim("width"), height: dim("height"))
        )
    }

    private func frameAlignment(_ token: String?) -> Alignment {
        switch token {
        case "leading": return .leading
        case "trailing": return .trailing
        case "top": return .top
        case "bottom": return .bottom
        case "topLeading": return .topLeading
        case "topTrailing": return .topTrailing
        case "bottomLeading": return .bottomLeading
        case "bottomTrailing": return .bottomTrailing
        default: return .center
        }
    }

    /// Resolves a font token, including the `.system(size:weight:design:)` /
    /// `.system(.style, design:)` forms (size, monospaced design, named style).
    private func resolveFont(_ token: String?) -> Font? {
        guard let token else { return nil }
        guard token.hasPrefix("system") else { return dslFont(named: token, size: nil) }
        let design: Font.Design = token.contains("monospaced") ? .monospaced : .default
        if let range = token.range(of: "size:") {
            let digits = token[range.upperBound...].drop(while: { $0 == " " })
                .prefix(while: { $0.isNumber || $0 == "." })
            if let n = Double(digits) { return .system(size: CGFloat(n), design: design) }
        }
        let styles: [(String, Font.TextStyle)] = [
            ("largeTitle", .largeTitle), ("title3", .title3), ("title2", .title2), ("title", .title),
            ("headline", .headline), ("subheadline", .subheadline), ("body", .body), ("callout", .callout),
            ("footnote", .footnote), ("caption2", .caption2), ("caption", .caption),
        ]
        for (name, style) in styles where token.contains(name) {
            return .system(style, design: design)
        }
        return .system(size: 13, design: design)
    }

    /// Strips a leading `.` (member token) or surrounding quotes from a raw
    /// modifier argument so color/font/alignment tokens resolve.
    private func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.hasPrefix(".") { return String(raw.dropFirst()) }
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }
}
