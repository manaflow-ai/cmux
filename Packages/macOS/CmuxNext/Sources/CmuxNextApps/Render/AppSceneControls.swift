import AppKit
import CmuxNextDesign
import SwiftUI

/// `Toggle`: the native switch, two-way bound like `TextField`. The scene's
/// `value` is the state; with `onChange`, a flip shows at once and sends
/// `change {value}`, and the next `value` the app sends wins. Without
/// `onChange` it only shows the app's value: a click does not flip it.
/// Inked with the scope's primary text, the emphasis cmux chrome uses (never
/// system blue).
struct AppSceneToggle: View {
    @Environment(\.appSceneColors) private var colors
    let model: AppSceneModel
    let id: String
    let node: AppSceneNode
    @State private var isOn: Bool

    init(model: AppSceneModel, id: String, node: AppSceneNode) {
        self.model = model
        self.id = id
        self.node = node
        _isOn = State(initialValue: node.flag("value"))
    }

    var body: some View {
        // A settings row: the label leading, the switch trailing, as the app's own switch rows.
        HStack(spacing: Metrics.space2) {
            if let label = node.string("label") {
                Text(label).font(Font(Typography.body)).foregroundStyle(colors.primary).lineLimit(1)
                Spacer(minLength: 0)
            }
            Toggle(node.string("label") ?? "", isOn: Binding(get: { isOn }, set: { new in
                guard node.flag("onChange") else { return }
                isOn = new
                model.send(id, "change", ["value": .bool(new)])
            }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(colors.primary)
            .labelsHidden()
        }
        .onChange(of: node.flag("value")) { _, new in if new != isOn { isOn = new } }
    }
}

/// `Slider`: the native slider over `min...max`, snapped to `step` (a
/// hundredth of the range when absent, so a drag sends at most about a
/// hundred `change {value}` events). Tracked in the scope's primary ink.
/// While a drag runs, the app's echoes of earlier values do not move the
/// thumb; the app's value is applied when the drag ends. Without `onChange`
/// it only shows the app's value.
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
        return min((snapped * scale).rounded() / scale, range.upperBound)
    }
}

/// `Panel`: a group on the app's own card surface, with the card's padding
/// and radius (`Metrics.space3`) and an optional title in the card's eyebrow
/// style. `glass` (the default) is the sidebar cards' surface
/// (`CardSurfaceView`, the shared neutral glass veil with its rim, tinted with
/// the theme); `card` is the opaque elevated fill with a separator hairline.
/// Both follow the theme live.
struct AppScenePanel<Content: View>: View {
    @Environment(\.appSceneColors) private var colors
    let node: AppSceneNode
    @ViewBuilder let content: () -> Content

    var body: some View {
        let radius = Metrics.space3
        VStack(alignment: .leading, spacing: node.number("spacing").map { CGFloat($0) } ?? Metrics.space2) {
            if let title = node.string("title"), !title.isEmpty {
                Text(title)
                    .font(Font(Typography.caption))
                    .foregroundStyle(colors.secondary)
                    .lineLimit(1)
            }
            content()
        }
        .padding(Metrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if node.string("style") == "card" {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(colors.elevated)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(colors.separator, lineWidth: 1))
            } else {
                AppSceneGlassSurface(cornerRadius: radius)
            }
        }
        .padding(.horizontal, Metrics.space3)
    }
}

/// The sidebar cards' surface (`CardSurfaceView`) behind a `Panel`.
struct AppSceneGlassSurface: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> CardSurfaceView {
        let view = CardSurfaceView(cornerRadius: cornerRadius)
        view.takesThemeTint = true
        return view
    }

    func updateNSView(_ view: CardSurfaceView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}
