import CmuxNextDesign
import SwiftUI

/// One tunable: label (with a dot when changed), key, help, its control,
/// the default, and Reset.
struct DebugTunableRowView: View {
    let model: DebugSettingsModel
    let descriptor: TunableDescriptor

    var body: some View {
        let changed = model.isChanged(descriptor)
        HStack(alignment: .top, spacing: Metrics.space5) {
            VStack(alignment: .leading, spacing: Metrics.space1) {
                HStack(spacing: Metrics.space3) {
                    Circle().fill(SettingsStyle.text).frame(width: Metrics.space3, height: Metrics.space3).opacity(changed ? 1 : 0)
                    Text(descriptor.label).font(changed ? SettingsStyle.emphasized : SettingsStyle.body)
                }
                Group {
                    Text(descriptor.key).font(SettingsStyle.keycap).foregroundStyle(SettingsStyle.tertiary).textSelection(.enabled)
                    if !descriptor.help.isEmpty {
                        Text(descriptor.help).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, Metrics.space3 + Metrics.space3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: Metrics.space1) {
                DebugTunableControl(model: model, descriptor: descriptor)
                Text(DebugSettingsStrings.defaultIs(DebugSettingsStrings.display(descriptor.defaultValue, kind: descriptor.kind)))
                    .font(SettingsStyle.caption).foregroundStyle(SettingsStyle.tertiary)
            }
            Button { model.reset(descriptor) } label: {
                Image(systemName: "arrow.uturn.backward").font(SettingsStyle.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(SettingsStyle.secondary)
            .help(SettingsWindowStrings.reset)
            .opacity(changed ? 1 : 0)
            .disabled(!changed)
            .padding(.top, Metrics.space1)
            .accessibilityIdentifier("cmux.debugSettings.reset.\(descriptor.key)")
        }
        .padding(.horizontal, Metrics.space5)
        .padding(.vertical, Metrics.space3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cmux.debugSettings.row.\(descriptor.key)")
    }
}

/// The control for a tunable's kind.
struct DebugTunableControl: View {
    let model: DebugSettingsModel
    let descriptor: TunableDescriptor

    var body: some View {
        let value = model.value(descriptor)
        switch descriptor.kind {
        case let .number(range, step, unit):
            DebugNumberField(value: Binding(get: { value.number ?? range.lowerBound },
                                            set: { model.set(descriptor, .number($0)) }),
                             range: range, step: step, unit: unit)
        case .bool:
            Toggle("", isOn: Binding(get: { value.bool ?? false }, set: { model.set(descriptor, .bool($0)) }))
                .labelsHidden().toggleStyle(.switch)
        case .choice(let options):
            Picker("", selection: Binding(get: { value.choice ?? "" }, set: { model.set(descriptor, .choice($0)) })) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        case .color:
            DebugColorPicker(selection: Binding(get: { value.color ?? .textPrimary }, set: { model.set(descriptor, .color($0)) }))
        case .spring:
            let spring = value.spring ?? MotionSpring.move.base
            VStack(alignment: .trailing, spacing: Metrics.space1) {
                DebugNumberField(title: DebugSettingsStrings.response,
                                 value: Binding(get: { spring.response }, set: {
                                     model.set(descriptor, .spring(SpringParameters(response: $0, dampingFraction: spring.dampingFraction)))
                                 }),
                                 range: TunableKind.springResponseRange.lowerBound...1, step: 0.005, unit: .seconds)
                DebugNumberField(title: DebugSettingsStrings.damping,
                                 value: Binding(get: { spring.dampingFraction }, set: {
                                     model.set(descriptor, .spring(SpringParameters(response: spring.response, dampingFraction: $0)))
                                 }),
                                 range: TunableKind.springDampingRange.lowerBound...1.2, step: 0.01, unit: .multiplier)
            }
        }
    }
}
