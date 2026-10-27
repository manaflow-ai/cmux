import CmuxNextDesign
import SwiftUI

/// Circle, Capsule, Rectangle, RoundedRectangle: `fill` or `stroke`, `size`.
struct AppSceneShape: View {
    @Environment(\.appSceneColors) private var colors
    let node: AppSceneNode

    var body: some View {
        let fill = colors.token(node.props["fill"])
        let stroke = colors.token(node.props["stroke"])
        let width = CGFloat(node.number("strokeWidth") ?? 1)
        let size = node.number("size").map { CGFloat($0) }
        shape
            .fill(fill ?? (stroke == nil ? colors.secondary : .clear))
            .overlay { if let stroke { shape.stroke(stroke, lineWidth: width) } }
            .frame(width: size, height: size)
    }

    private var shape: AnyShape {
        switch node.type {
        case .circle: AnyShape(Circle())
        case .capsule: AnyShape(Capsule())
        case .roundedRectangle: AnyShape(RoundedRectangle(cornerRadius: CGFloat(node.number("cornerRadius") ?? 4), style: .continuous))
        default: AnyShape(Rectangle())
        }
    }
}

/// A TextField node: local text, `edit` on change, `submit` on Return,
/// `cancel` on Escape. A themed field: its text, caret and placeholder are
/// the scope's inks. Its text starts as the node's where the view is made, not
/// on appear: a gated page tab appears again on each show
/// (`VisibilityGatedHostingView`), and a reset would lose the typed text and
/// send the app an `edit` the person did not make.
struct AppSceneTextField: View {
    let model: AppSceneModel
    let id: String
    let node: AppSceneNode
    @State private var text: String

    init(model: AppSceneModel, id: String, node: AppSceneNode) {
        self.model = model
        self.id = id
        self.node = node
        _text = State(initialValue: node.string("text") ?? "")
    }

    var body: some View {
        ThemedField(text: $text, placeholder: node.string("placeholder"), height: 18, focusOnAppear: node.flag("autofocus"),
                    boxed: false, onSubmit: { model.send(id, "submit", ["text": .string(text)]) },
                    onCancel: { model.send(id, "cancel") })
            .onChange(of: node.string("text")) { _, new in if let new, new != text { text = new } }
            .onChange(of: text) { _, new in if node.flag("onEdit") { model.send(id, "edit", ["text": .string(new)]) } }
    }
}
