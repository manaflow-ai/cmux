import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// One schema setting: title, help, the control for its kind, Reset when
/// the file sets it, and the load diagnostic when the file's value is bad.
struct SettingRowView: View {
    let model: SettingsWindowModel
    let descriptor: SettingDescriptor
    /// Search results: the title is a link that opens the row on its page.
    var onOpen: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            HStack(spacing: Metrics.space4) {
                VStack(alignment: .leading, spacing: 0) {
                    if let onOpen {
                        SettingsJumpTitle(title: descriptor.title, action: onOpen)
                            .accessibilityIdentifier("cmux.settings.open.\(descriptor.id)")
                    } else {
                        Text(descriptor.title)
                    }
                    if let help = descriptor.help {
                        Text(help).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let managed = model.managedNote(descriptor) {
                        Label(managed, systemImage: "lock.fill").font(SettingsStyle.caption).foregroundStyle(SettingsStyle.secondary)
                            .accessibilityIdentifier("cmux.settings.managed.\(descriptor.id)")
                    }
                }
                Spacer(minLength: Metrics.space6)
                SettingControl(model: model, descriptor: descriptor)
                    .disabled(model.isManaged(descriptor))
                Button { model.set(descriptor, nil) } label: {
                    Image(systemName: "arrow.uturn.backward").font(SettingsStyle.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SettingsStyle.secondary)
                .help(SettingsWindowStrings.reset)
                .opacity(model.isCustomized(descriptor) ? 1 : 0)
                .disabled(!model.isCustomized(descriptor))
                .accessibilityIdentifier("cmux.settings.reset.\(descriptor.id)")
            }
            if let problem = model.diagnostic(descriptor) {
                Text(problem).font(SettingsStyle.caption).foregroundStyle(SettingsStyle.danger)
            }
        }
        .padding(.horizontal, Metrics.space5)
        .padding(.vertical, Metrics.space2)
        .frame(minHeight: SettingsStyle.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cmux.settings.row.\(descriptor.id)")
    }
}

/// The control for a setting's kind.
struct SettingControl: View {
    let model: SettingsWindowModel
    let descriptor: SettingDescriptor

    var body: some View {
        switch descriptor.kind {
        case .choice(let choices): ChoiceControl(model: model, descriptor: descriptor, choices: choices)
        case .choiceOrNumber(let choices, let number): ChoiceOrNumberControl(model: model, descriptor: descriptor, choices: choices, number: number)
        case .toggle:
            Toggle("", isOn: Binding(
                get: { model.value(descriptor)?.boolValue ?? false },
                set: { model.set(descriptor, .bool($0)) }))
                .labelsHidden().toggleStyle(.switch)
        case .number(let number): NumberControl(model: model, descriptor: descriptor, number: number)
        case .color: ColorControl(model: model, descriptor: descriptor)
        case .sound: SoundControl(model: model, descriptor: descriptor)
        case .url: AddressControl(model: model, descriptor: descriptor)
        case .hostList: HostListControl(model: model, descriptor: descriptor)
        case .folderList:
            HostListControl(model: model, descriptor: descriptor, placeholder: SettingsWindowStrings.folderPlaceholder, normalize: { $0 })
        case .timeRange: TimeRangeControl(model: model, descriptor: descriptor)
        case .theme: AppThemeControl(model: model, descriptor: descriptor)
        case .fontFamily: FontFamilyControl(model: model, descriptor: descriptor)
        // Only cmux-browser keys have these kinds; `SettingsSchema.settings(in:)` never lists them here.
        case .numberList, .stringMap: EmptyView()
        }
    }
}
