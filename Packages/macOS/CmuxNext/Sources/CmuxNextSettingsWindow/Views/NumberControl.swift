import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// A slider (points, seconds, fractions) or a stepper (counts).
struct NumberControl: View {
    let model: SettingsWindowModel
    let descriptor: SettingDescriptor
    let number: SettingNumber

    var body: some View {
        let stored = model.value(descriptor)?.doubleValue
        let shown = stored ?? model.host?.derivedNumber(at: descriptor.path) ?? number.placeholder
        let binding = Binding<Double>(get: { shown }, set: { model.set(descriptor, .number(NumberText.snap($0, number))) })
        HStack(spacing: Metrics.space4) {
            if number.unit == .count {
                Stepper(value: binding, in: number.range, step: number.step) { EmptyView() }.labelsHidden()
            } else {
                Slider(value: binding, in: number.range, step: number.step)
                    .frame(minWidth: Metrics.sidebarWidth * 0.4, maxWidth: Metrics.sidebarWidth * 0.7)
            }
            Text(stored.map { NumberText.format($0, unit: number.unit) } ?? descriptor.defaultLabel ?? "")
                .monospacedDigit().foregroundStyle(SettingsStyle.secondary)
                .lineLimit(1).fixedSize()
                .frame(minWidth: Metrics.tabMinWidth * 2, alignment: .trailing)
                .layoutPriority(1)
        }
    }
}

/// Number display and snapping for the controls.
enum NumberText {
    static func snap(_ value: Double, _ number: SettingNumber) -> Double {
        let steps = ((value - number.range.lowerBound) / number.step).rounded()
        let snapped = number.range.lowerBound + steps * number.step
        return (min(max(snapped, number.range.lowerBound), number.range.upperBound) * 1000).rounded() / 1000
    }

    static func format(_ value: Double, unit: SettingNumber.Unit) -> String {
        if unit == .fraction { return value.formatted(.percent.precision(.fractionLength(0))) }
        let text = value.formatted(.number.precision(.fractionLength(0...1)))
        switch unit {
        case .points: return SettingsWindowStrings.points(text)
        case .seconds: return SettingsWindowStrings.seconds(text)
        case .minutes: return SettingsWindowStrings.minutes(text)
        case .count, .fraction: return text
        }
    }
}
