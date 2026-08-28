import CmuxFoundation
import SwiftUI

/// The New Machine sheet: name, kind, size, what the plan allows, and the
/// backend's error verbatim when a create fails. Presented by
/// ``NewMachineSheetPresenter`` as a window sheet on the main window.
struct NewMachineSheet: View {
    @Bindable var model: NewMachineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            fields
            planSection
            if let errorText = model.errorText {
                errorBox(errorText)
            }
            buttons
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityIdentifier("NewMachineSheet")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.isBaseSetup
                ? String(localized: "machines.new.title.base", defaultValue: "Set Up Base")
                : String(localized: "machines.new.title", defaultValue: "New Machine"))
                .cmuxFont(size: 15, weight: .semibold)
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

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            if model.supportsName {
                GridRow {
                    label(String(localized: "machines.new.name.label", defaultValue: "Name"))
                    TextField(
                        String(localized: "machines.new.name.placeholder", defaultValue: "Optional label"),
                        text: $model.name
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isCreating)
                    .accessibilityIdentifier("NewMachineSheet.name")
                }
            }
            GridRow {
                label(String(localized: "machines.new.kind.label", defaultValue: "Kind"))
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $model.kind) {
                        ForEach(VMMachineKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(model.isCreating)
                    .accessibilityIdentifier("NewMachineSheet.kind")
                    Text(model.kind.summary)
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.supportsSize {
                GridRow {
                    label(String(localized: "machines.new.size.label", defaultValue: "Size"))
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $model.memoryMb) {
                            ForEach(model.memoryOptions, id: \.self) { mb in
                                Text(NewMachineModel.memoryLabel(mb: mb)).tag(mb)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 140, alignment: .leading)
                        .disabled(model.isCreating)
                        .accessibilityIdentifier("NewMachineSheet.size")
                        Text(String(
                            localized: "machines.new.size.summary",
                            defaultValue: "Memory. CPU scales with it."
                        ))
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if let image = model.selectedImage {
                GridRow {
                    label(String(localized: "machines.new.image.label", defaultValue: "Image"))
                    Text(image)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("NewMachineSheet.image")
                }
            }
        }
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
        HStack(spacing: 8) {
            if model.isCreating {
                ProgressView()
                    .controlSize(.small)
                Text(model.isBaseSetup
                    ? String(localized: "machines.new.creating.base", defaultValue: "Setting up Base…")
                    : String(localized: "machines.new.creating", defaultValue: "Creating…"))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "machines.new.cancel", defaultValue: "Cancel")) {
                model.cancel()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isCreating)
            .accessibilityIdentifier("NewMachineSheet.cancel")
            Button(createTitle) {
                model.create()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isCreating)
            .accessibilityIdentifier("NewMachineSheet.create")
        }
    }

    private var createTitle: String {
        if model.createdMachineID != nil {
            return String(localized: "machines.new.done", defaultValue: "Done")
        }
        if model.errorText != nil {
            return String(localized: "machines.new.retry", defaultValue: "Retry")
        }
        return model.isBaseSetup
            ? String(localized: "machines.new.create.base", defaultValue: "Set Up Base")
            : String(localized: "machines.new.create", defaultValue: "Create")
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .cmuxFont(size: 12)
            .gridColumnAlignment(.trailing)
    }
}
