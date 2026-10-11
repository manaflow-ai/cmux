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
/// `cancel` on Escape.
struct AppSceneTextField: View {
    let model: AppSceneModel
    let id: String
    let node: AppSceneNode
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(node.string("placeholder") ?? "", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear {
                text = node.string("text") ?? ""
                if node.flag("autofocus") { focused = true }
            }
            .onChange(of: node.string("text")) { _, new in if let new, new != text { text = new } }
            .onChange(of: text) { _, new in if node.flag("onEdit") { model.send(id, "edit", ["text": .string(new)]) } }
            .onSubmit { model.send(id, "submit", ["text": .string(text)]) }
            .onExitCommand { model.send(id, "cancel") }
    }
}
