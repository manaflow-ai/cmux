import CmuxNextDesign
import SwiftUI

/// Layout and surface props every node accepts, plus interaction: a local
/// hover wash (`hoverBackground`, no JS round trip), tap, context menu and
/// help. Hover animates only without Reduce Motion.
struct AppSceneDecorations: ViewModifier {
    @Environment(\.appSceneColors) private var colors
    let model: AppSceneModel
    let id: String
    let node: AppSceneNode
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let frame = node.props["frame"]?.objectValue
        let radius = CGFloat(node.number("cornerRadius") ?? 0)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let hoverFill = colors.token(node.props["hoverBackground"])
        content
            .padding(AppSceneStyle.insets(node))
            .frame(minWidth: AppSceneStyle.dimension(frame, "minWidth"), idealWidth: AppSceneStyle.dimension(frame, "width"),
                   maxWidth: AppSceneStyle.dimension(frame, "maxWidth") ?? AppSceneStyle.dimension(frame, "width"),
                   minHeight: AppSceneStyle.dimension(frame, "minHeight"), idealHeight: AppSceneStyle.dimension(frame, "height"),
                   maxHeight: AppSceneStyle.dimension(frame, "maxHeight") ?? AppSceneStyle.dimension(frame, "height"),
                   alignment: .leading)
            .background {
                ZStack {
                    if let fill = colors.token(node.props["background"]) { shape.fill(fill) }
                    if isHovered, let hoverFill { shape.fill(hoverFill) }
                }
            }
            .overlay {
                if let border = colors.token(node.props["borderColor"]) {
                    shape.strokeBorder(border, lineWidth: CGFloat(node.number("borderWidth") ?? 1))
                }
            }
            .clipShape(shape)
            .opacity(node.number("opacity").map { min(max($0, 0), 1) } ?? 1)
            .rotationEffect(.degrees(node.number("rotation") ?? 0))
            .layoutPriority(node.number("layoutPriority") ?? 0)
            .fixedSize(horizontal: fixed(.horizontal), vertical: fixed(.vertical))
            .disabled(node.flag("disabled"))
            .help(node.string("help") ?? "")
            .contentShape(shape)
            .onHover { hovering in
                guard hoverFill != nil else { return }
                isHovered = hovering
            }
            .animation(reduceMotion ? nil : Motion.animation(.hover), value: isHovered)
            .modifier(AppSceneTap(enabled: node.flag("onTap") && node.type != .button) { model.send(id, "tap") })
            .contextMenu(node.type == .menu ? nil : menu)
    }

    private var menu: ContextMenu<AnyView>? {
        guard let items = node.props["menu"]?.arrayValue, !items.isEmpty else { return nil }
        return ContextMenu {
            AnyView(AppSceneMenuItems(items: items, path: []) { path in
                model.send(id, "menu", ["path": .array(path.map { .number(Double($0)) })])
            })
        }
    }

    private func fixed(_ axis: Axis) -> Bool {
        switch node.string("fixedSize") {
        case "both": true
        case "horizontal": axis == .horizontal
        case "vertical": axis == .vertical
        default: false
        }
    }
}

/// Tap for a node with an `onTap` handler.
struct AppSceneTap: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled { content.onTapGesture(perform: action) } else { content }
    }
}

