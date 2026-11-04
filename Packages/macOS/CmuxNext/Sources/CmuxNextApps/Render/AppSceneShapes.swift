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
/// the scope's inks.
struct AppSceneTextField: View {
    let model: AppSceneModel
    let id: String
    let node: AppSceneNode
    @State private var text = ""

    var body: some View {
        ThemedField(text: $text, placeholder: node.string("placeholder"), height: 18, focusOnAppear: node.flag("autofocus"),
                    boxed: false, onSubmit: { model.send(id, "submit", ["text": .string(text)]) },
                    onCancel: { model.send(id, "cancel") })
            .onAppear { text = node.string("text") ?? "" }
            .onChange(of: node.string("text")) { _, new in if let new, new != text { text = new } }
            .onChange(of: text) { _, new in if node.flag("onEdit") { model.send(id, "edit", ["text": .string(new)]) } }
    }
}

/// `Slider`: the native slider over `min...max`, snapped to `step` (a
/// hundredth of the range when absent, so a drag sends at most about a
/// hundred `change {value}` events). Tracked in the scope's primary ink.
/// While a drag runs, the app's echoes of earlier values do not move the
/// thumb; the app's value is applied when the drag ends. Without `onChange`
/// it only shows the app's value, disabled.
struct AppSceneSlider: View {
    @Environment(\.appSceneColors) private var colors
    let model: AppSceneModel
    let id: String
    let node: AppSceneNode
    @State private var value: Double
    @State private var editing = false

    init(model: AppSceneModel, id: String, node: AppSceneNode) {
        self.model = model
        self.id = id
        self.node = node
        let range = Self.range(node)
        _value = State(initialValue: Self.snap(node.number("value") ?? range.lowerBound, range, Self.step(node, range)))
    }

    var body: some View {
        let range = Self.range(node)
        let step = Self.step(node, range)
        Slider(value: Binding(get: { value }, set: { new in
            guard node.flag("onChange") else { return }
            let snapped = Self.snap(new, range, step)
            guard snapped != value else { return }
            value = snapped
            model.send(id, "change", ["value": .number(snapped)])
        }), in: range, onEditingChanged: { active in
            editing = active
            if !active { sync(range, step) }
        })
        .controlSize(.small)
        .tint(colors.primary)
        .disabled(node.flag("disabled") || !node.flag("onChange"))
        .onChange(of: node.number("value")) { _, _ in if !editing { sync(range, step) } }
    }

    /// Shows the app's value (snapped), unless it already shows.
    private func sync(_ range: ClosedRange<Double>, _ step: Double) {
        let shown = Self.snap(node.number("value") ?? range.lowerBound, range, step)
        if shown != value { value = shown }
    }

    /// `min...max`; an empty or reversed range is the default 0...1.
    static func range(_ node: AppSceneNode) -> ClosedRange<Double> {
        let low = node.number("min") ?? 0, high = node.number("max") ?? 1
        return low.isFinite && high.isFinite && low < high ? low...high : 0...1
    }

    static func step(_ node: AppSceneNode, _ range: ClosedRange<Double>) -> Double {
        if let step = node.number("step"), step.isFinite, step > 0 { return step }
        return (range.upperBound - range.lowerBound) / 100
    }

    /// `value` clamped to `range` and snapped to the nearest step from its lower bound.
    static func snap(_ value: Double, _ range: ClosedRange<Double>, _ step: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let snapped = range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step
        // Round to the step's own decimals, so a 0.1 step sends 0.3, not 0.30000000000000004.
        let decimals = Double(min(max(Int((-log10(step)).rounded(.up)) + 6, 0), 12))
        let scale = pow(10, decimals)
        return min(max((snapped * scale).rounded() / scale, range.lowerBound), range.upperBound)
    }
}
