import CmuxFoundation
import SwiftUI

/// The New Machine sheet: one base-image size and what the plan allows.
/// Presented by ``NewMachineSheetPresenter`` as a window sheet on the main
/// window. Create closes it at once; the machine coming up is shown by the
/// Machines panel, not here, so the sheet never holds the window.
struct NewMachineSheet: View {
    @Bindable var model: NewMachineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.supportsSize {
                sizeSection
            }
            planSection
            if let errorText = model.errorText {
                errorBox(errorText)
            }
            buttons
        }
        .padding(24)
        .frame(width: 500)
        .accessibilityIdentifier("NewMachineSheet")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.isBaseSetup ? "externaldrive.fill" : "cpu")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(model.isBaseSetup
                    ? String(localized: "machines.new.title.base", defaultValue: "Set Up Base")
                    : String(localized: "machines.new.title", defaultValue: "New Machine"))
                    .cmuxFont(size: 16, weight: .semibold)
                Text(model.isBaseSetup
                    ? String(
                        localized: "machines.new.subtitle.base",
                        defaultValue: "Base is your persistent cloud machine. Opening it later reuses this same machine; reset Base to start over."
                    )
                    : String(
                        localized: "machines.new.subtitle",
                        defaultValue: "A cloud computer with devtools and coding agents preinstalled. It keeps its home directory between sessions."
                    ))
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "machines.new.size.label", defaultValue: "Machine size"))
                        .cmuxFont(size: 13, weight: .semibold)
                    Text(String(
                        localized: "machines.new.size.help",
                        defaultValue: "Choose the memory and disk profile for this machine."
                    ))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(String(localized: "machines.new.size.required", defaultValue: "Required"))
                    .cmuxFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            if let selectedSize = model.selectedSize {
                Picker(selection: $model.memoryMb) {
                    ForEach(model.memoryOptions, id: \.self) { memoryMb in
                        if let size = MachineSizeOption(memoryMb: memoryMb) {
                            Text(size.menuTitle).tag(memoryMb)
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "memorychip")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedSize.title)
                                .cmuxFont(size: 13, weight: .semibold)
                            Text(selectedSize.detail)
                                .cmuxFont(size: 11)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .accessibilityIdentifier("NewMachineSheet.size")
                .accessibilityLabel(String(localized: "machines.new.size.accessibilityLabel", defaultValue: "RAM size"))
                .accessibilityValue(selectedSize.menuTitle)
            }

            if let selectedSize = model.selectedSize {
                HStack(spacing: 0) {
                    resourceMetric(
                        symbol: "memorychip",
                        label: String(localized: "machines.new.size.ram", defaultValue: "RAM"),
                        value: selectedSize.title
                    )
                    resourceDivider
                    resourceMetric(
                        symbol: "internaldrive",
                        label: String(localized: "machines.new.size.disk", defaultValue: "Disk"),
                        value: selectedSize.diskTitle
                    )
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("NewMachineSheet.resources")
            }
        }
        .padding(13)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
        .accessibilityIdentifier("NewMachineSheet.sizeSection")
    }

    private var resourceDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 26)
            .padding(.horizontal, 9)
    }

    private func resourceMetric(symbol: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased())
                    .cmuxFont(size: 9, weight: .medium)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .cmuxFont(size: 11, weight: .medium, monospacedDigit: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var planSection: some View {
        if model.planMeterText != nil || model.freeAccessNoteText != nil {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 3) {
                    if let meter = model.planMeterText {
                        Text(meter)
                            .cmuxFont(size: 11, weight: .medium)
                            .foregroundStyle(.secondary)
                    }
                    if let note = model.freeAccessNoteText {
                        Text(note)
                            .cmuxFont(size: 11)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .accessibilityIdentifier("NewMachineSheet.plan")
        }
    }

    private func errorBox(_ text: String) -> some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 160)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("NewMachineSheet.error")
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Divider()
            HStack(alignment: .center, spacing: 8) {
                Text(model.isBaseSetup
                    ? String(localized: "machines.new.background.note.base", defaultValue: "Setup continues in the Machines panel.")
                    : String(localized: "machines.new.background.note", defaultValue: "Creation continues in the Machines panel."))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("NewMachineSheet.backgroundNote")
                Spacer()
                Button(String(localized: "machines.new.cancel", defaultValue: "Cancel")) {
                    model.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("NewMachineSheet.cancel")
                Button(createTitle) {
                    model.create()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("NewMachineSheet.create")
            }
        }
        .padding(.top, 2)
    }

    private var createTitle: String {
        if model.errorText != nil {
            return String(localized: "machines.new.retry", defaultValue: "Retry")
        }
        return model.isBaseSetup
            ? String(localized: "machines.new.create.base", defaultValue: "Set Up Base")
            : String(localized: "machines.new.create", defaultValue: "Create")
    }

}
