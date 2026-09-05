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
        .frame(width: 520)
        .accessibilityIdentifier("NewMachineSheet")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.isBaseSetup
                ? String(localized: "machines.new.title.base", defaultValue: "Set Up Base")
                : String(localized: "machines.new.title", defaultValue: "New Machine"))
                .cmuxFont(size: 19, weight: .semibold)
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

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(model.memoryOptions, id: \.self) { memoryMb in
                    if let size = MachineSizeOption(memoryMb: memoryMb) {
                        sizeOption(size)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
        .accessibilityIdentifier("NewMachineSheet.sizeSection")
    }

    private func sizeOption(_ size: MachineSizeOption) -> some View {
        let isSelected = model.memoryMb == size.memoryMb
        return Button {
            model.memoryMb = size.memoryMb
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(size.title)
                        .cmuxFont(size: 13, weight: .semibold)
                    Text(size.detail)
                        .cmuxFont(size: 11)
                        .foregroundStyle(isSelected ? Color.primary.opacity(0.78) : Color.secondary)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.76) : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("NewMachineSheet.size.\(size.memoryMb)")
        .accessibilityLabel(size.menuTitle)
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : [])
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
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
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
