#if os(iOS) && DEBUG
import CmuxMobileSupport
import SwiftUI

extension MobileSettingsView {
    func developerLayoutSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(developerPointValue(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 1)
        }
        .accessibilityIdentifier(identifier)
    }

    private func developerPointValue(_ value: Double) -> String {
        String(
            format: L10n.string("mobile.settings.pointsFormat", defaultValue: "%lld pt"),
            Int64(value.rounded())
        )
    }
}
#endif
