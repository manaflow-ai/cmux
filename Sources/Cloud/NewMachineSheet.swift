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

            if let selectedSize = model.selectedSize {
                Picker(selection: $model.memoryMb) {
                    ForEach(model.memoryOptions, id: \.self) { memoryMb in
                        if let size = MachineSizeOption(memoryMb: memoryMb) {
                            Text(size.menuTitle).tag(memoryMb)
                        }
                    }
                } label: {
                    Text(selectedSize.menuTitle)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityIdentifier("NewMachineSheet.size")
                .accessibilityLabel(String(localized: "machines.new.size.accessibilityLabel", defaultValue: "RAM size"))
                .accessibilityValue(selectedSize.menuTitle)
            }
        }
        .accessibilityIdentifier("NewMachineSheet.sizeSection")
    }

    @ViewBuilder
    private var planSection: some View {
        if model.planMeterText != nil || model.freeAccessNoteText != nil {
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

#if DEBUG
/// Plain SwiftUI alternatives for reviewing the size control without a web mockup.
/// These views are preview-only. The sheet uses the first variation: the native menu.
private struct NewMachinePickerVariationsPreview: View {
    @State private var selectedMemoryMb = 8192
    var viewportHeight: CGFloat = 820

    private static let sizes = NewMachineModel.memoryOptionsMb
        .compactMap { MachineSizeOption(memoryMb: $0) }

    private var selectedSize: MachineSizeOption {
        MachineSizeOption(memoryMb: selectedMemoryMb) ?? Self.sizes[1]
    }

    private var selectedIndex: Int {
        Self.sizes.firstIndex(where: { $0.memoryMb == selectedMemoryMb }) ?? 0
    }

    private var selectedIndexBinding: Binding<Int> {
        Binding(
            get: { selectedIndex },
            set: { selectedMemoryMb = Self.sizes[$0].memoryMb }
        )
    }

    private var selectedIndexDoubleBinding: Binding<Double> {
        Binding(
            get: { Double(selectedIndex) },
            set: {
                let index = min(max(Int($0.rounded()), 0), Self.sizes.count - 1)
                selectedMemoryMb = Self.sizes[index].memoryMb
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "machines.new.size.label", defaultValue: "Machine size"))
                    .font(.headline)
                Text(String(
                    localized: "machines.new.size.help",
                    defaultValue: "Choose the memory and disk profile for this machine."
                ))
                .foregroundStyle(.secondary)

                variation(1) {
                    Picker(selection: $selectedMemoryMb) {
                        sizeOptions
                    } label: {
                        Text(selectedSize.menuTitle)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                variation(2) {
                    Picker(selection: $selectedMemoryMb) {
                        ForEach(Self.sizes, id: \.memoryMb) { size in
                            Text(size.title).tag(size.memoryMb)
                        }
                    } label: {
                        Text(selectedSize.menuTitle)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                variation(3) {
                    Picker(selection: $selectedMemoryMb) {
                        sizeOptions
                    } label: {
                        Text(selectedSize.menuTitle)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                variation(4) {
                    Stepper(value: selectedIndexBinding, in: 0...(Self.sizes.count - 1)) {
                        Text(selectedSize.menuTitle)
                    }
                }

                variation(5) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedSize.menuTitle)
                        Slider(value: selectedIndexDoubleBinding, in: 0...Double(Self.sizes.count - 1), step: 1)
                    }
                }

                variation(6) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Self.sizes, id: \.memoryMb) { size in
                            Button {
                                selectedMemoryMb = size.memoryMb
                            } label: {
                                HStack {
                                    Text(size.menuTitle)
                                    Spacer()
                                    if size.memoryMb == selectedMemoryMb {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                variation(7) {
                    DisclosureGroup(selectedSize.menuTitle) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Self.sizes, id: \.memoryMb) { size in
                                Button(size.menuTitle) {
                                    selectedMemoryMb = size.memoryMb
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                variation(8) {
                    Menu {
                        ForEach(Self.sizes, id: \.memoryMb) { size in
                            Button(size.menuTitle) {
                                selectedMemoryMb = size.memoryMb
                            }
                        }
                    } label: {
                        Text(selectedSize.menuTitle)
                    }
                }

                variation(9) {
                    Picker(selection: $selectedMemoryMb) {
                        sizeOptions
                    } label: {
                        Text(String(localized: "machines.new.size.label", defaultValue: "Machine size"))
                    }
                }

                variation(10) {
                    HStack(spacing: 8) {
                        Button {
                            selectedMemoryMb = Self.sizes[max(selectedIndex - 1, 0)].memoryMb
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.bordered)
                        Text(selectedSize.menuTitle)
                        Button {
                            selectedMemoryMb = Self.sizes[min(selectedIndex + 1, Self.sizes.count - 1)].memoryMb
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .frame(width: 588, alignment: .leading)
            .padding()
        }
        .frame(width: 620, height: viewportHeight)
    }

    @ViewBuilder
    private var sizeOptions: some View {
        ForEach(Self.sizes, id: \.memoryMb) { size in
            Text(size.menuTitle).tag(size.memoryMb)
        }
    }

    @ViewBuilder
    private func variation<Content: View>(
        _ number: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: "%02d", number))
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
            Divider()
        }
    }
}

private struct NewMachinePickerVariationsPreview_Previews: PreviewProvider {
    static var previews: some View {
        NewMachinePickerVariationsPreview()
    }
}
#endif
