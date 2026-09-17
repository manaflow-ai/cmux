import CmuxSettings
import SwiftUI

/// A labeled `Stepper` bound to a `Double` ``DefaultsKey``.
///
/// Used for bounded floating-point settings (agent hibernation idle
/// seconds, etc.). The caller supplies the inclusive range and a step
/// granularity. The current value is rendered with the supplied
/// ``format`` so callers can show it as percent, seconds, points, etc.
@MainActor
public struct SettingsDoubleStepperRow: View {
    private let model: DefaultsValueModel<Double>
    private let title: String
    private let range: ClosedRange<Double>
    private let step: Double
    private let format: (Double) -> String

    public init(
        model: DefaultsValueModel<Double>,
        title: String,
        range: ClosedRange<Double>,
        step: Double = 1,
        format: @escaping (Double) -> String = { String(format: "%.0f", $0) }
    ) {
        self.model = model
        self.title = title
        self.range = range
        self.step = step
        self.format = format
    }

    public var body: some View {
        Stepper(value: Binding(
            get: { model.current },
            set: { model.set($0) }
        ), in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text(format(model.current))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .task { model.startObserving() }
    }
}
