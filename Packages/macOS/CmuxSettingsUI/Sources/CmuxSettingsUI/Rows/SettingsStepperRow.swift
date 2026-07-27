import CmuxSettings
import SwiftUI

/// A labeled `Stepper` bound to an `Int` ``DefaultsKey``.
///
/// Used for bounded integer settings (port base, max live terminals,
/// etc.). The caller supplies the inclusive range.
@MainActor
public struct SettingsStepperRow: View {
    private let model: DefaultsValueModel<Int>
    private let title: String
    private let range: ClosedRange<Int>

    public init(
        model: DefaultsValueModel<Int>,
        title: String,
        range: ClosedRange<Int>
    ) {
        self.model = model
        self.title = title
        self.range = range
    }

    public var body: some View {
        Stepper(value: Binding(
            get: { model.current },
            set: { model.set($0) }
        ), in: range) {
            HStack {
                Text(title)
                Spacer()
                Text("\(model.current)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .task { model.startObserving() }
    }
}
