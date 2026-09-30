import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// A segmented control for up to three short choices, else a pop-up. A
/// setting with a derived default ("Same as above") offers it first.
struct ChoiceControl: View {
    let model: SettingsWindowModel
    let descriptor: SettingDescriptor
    let choices: [SettingChoice]

    var body: some View {
        let inherit = descriptor.defaultValue == nil ? descriptor.defaultLabel : nil
        let selection = Binding<String>(
            get: { model.value(descriptor)?.stringValue ?? "" },
            set: { model.set(descriptor, $0.isEmpty ? nil : .string($0)) })
        let segmented = inherit == nil && choices.count <= 3 && choices.allSatisfy { $0.title.count <= 12 }
        Picker("", selection: selection) {
            if let inherit { Text(inherit).tag("") }
            ForEach(choices, id: \.value) { Text($0.title).tag($0.value) }
        }
        .labelsHidden()
        .fixedSize()
        .modifier(PickerStyleModifier(segmented: segmented))
    }
}

struct PickerStyleModifier: ViewModifier {
    let segmented: Bool

    func body(content: Content) -> some View {
        if segmented { content.pickerStyle(.segmented) } else { content.pickerStyle(.menu) }
    }
}

/// Fixed choices plus Custom with a number (browser hibernation minutes).
struct ChoiceOrNumberControl: View {
    let model: SettingsWindowModel
    let descriptor: SettingDescriptor
    let choices: [SettingChoice]
    let number: SettingNumber
    static let customTag = "\u{0}custom"

    var body: some View {
        let current = model.value(descriptor)
        let minutes = current?.doubleValue
        HStack(spacing: Metrics.space3) {
            Picker("", selection: Binding<String>(
                get: { minutes != nil ? Self.customTag : current?.stringValue ?? "" },
                set: { $0 == Self.customTag ? model.set(descriptor, .number(minutes ?? number.placeholder)) : model.set(descriptor, .string($0)) })) {
                ForEach(choices, id: \.value) { Text($0.title).tag($0.value) }
                Text(SettingsWindowStrings.custom).tag(Self.customTag)
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            if let minutes {
                Stepper(value: Binding(get: { minutes }, set: { model.set(descriptor, .number(min(max($0, number.range.lowerBound), number.range.upperBound))) }),
                        in: number.range, step: number.step) {
                    Text(NumberText.format(minutes, unit: number.unit)).monospacedDigit()
                }
            }
        }
    }
}
