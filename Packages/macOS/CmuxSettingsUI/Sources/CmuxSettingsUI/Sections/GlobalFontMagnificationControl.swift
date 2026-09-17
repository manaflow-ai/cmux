import CmuxFoundation
import SwiftUI

struct GlobalFontMagnificationControl: View {
    let percent: Int
    let onChange: (Int) -> Void

    private let minimum = GlobalFontMagnification.minimumPercent
    private let maximum = GlobalFontMagnification.maximumPercent
    private let step = GlobalFontMagnification.stepPercent

    private var clampedPercent: Int {
        GlobalFontMagnification.clamp(percent)
    }

    private var isAtDefault: Bool {
        clampedPercent == GlobalFontMagnification.defaultPercent
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%d%%", clampedPercent))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(minWidth: 48, alignment: .trailing)

            Stepper(
                "",
                value: Binding(
                    get: { clampedPercent },
                    set: { onChange(GlobalFontMagnification.clamp($0)) }
                ),
                in: minimum...maximum,
                step: step
            )
            .labelsHidden()
            .accessibilityLabel(String(localized: "settings.app.globalFontMagnification", defaultValue: "Global Font Magnification"))
            .accessibilityValue(Text("\(clampedPercent)%"))
            .accessibilityIdentifier("SettingsGlobalFontMagnificationStepper")

            Button(String(localized: "settings.app.globalFontMagnification.reset", defaultValue: "Reset")) {
                onChange(GlobalFontMagnification.defaultPercent)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isAtDefault)
        }
        .cmuxFont(.body)
    }
}
