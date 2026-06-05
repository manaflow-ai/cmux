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
        case .hsplit:
            ResizableHSplit(columns: node.children)
        case .reorderable:
            ReorderableList(rows: node.children, spec: node.reorder)
        case .text:
            Text(node.text ?? "")
        case .image:
            Image(systemName: node.systemName ?? "questionmark.square.dashed")
        case .button:
            if node.children.isEmpty {
                Button(node.text ?? "") {
                    if let action = node.action { dispatch.run(action) }
                }
            } else {
                // Rich label form: `Button(action:){ label }`. Plain style so
                // the label renders as authored, not as default button chrome.
                Button {
                    if let action = node.action { dispatch.run(action) }
                } label: {
                    VStack(alignment: .leading, spacing: 0) { children }
                }
                .buttonStyle(.plain)
            }
        case .spacer:
            Spacer(minLength: node.spacing.map { CGFloat($0) })
        case .divider:
            Divider()
        case .rectangle:
            Rectangle()
        case .roundedRectangle:
            RoundedRectangle(cornerRadius: CGFloat(node.cornerRadius ?? 6))
        case .capsule:
            Capsule()
        case .circle:
            Circle()
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
        case "fontWeight":
            return AnyView(view.fontWeight(dslFontWeight(token)))
        case "foregroundColor", "foregroundStyle", "fill", "tint":
            if let color = dslColor(token) { return AnyView(view.foregroundStyle(color)) }
            return view
        case "padding":
            if let token, let value = Double(token) { return AnyView(view.padding(CGFloat(value))) }
            return AnyView(view.padding())
        case "background":
            if let color = dslColor(token) { return AnyView(view.background(color)) }
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
        default:
            return view
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
