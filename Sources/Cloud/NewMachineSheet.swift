import CmuxFoundation
import SwiftUI

/// The New Machine sheet: name, kind, size, and what the plan allows.
/// Presented by ``NewMachineSheetPresenter`` as a window sheet on the main
/// window. Create closes it at once; the machine coming up is shown by the
/// Machines panel, not here, so the sheet never holds the window.
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
                    .accessibilityIdentifier("NewMachineSheet.name")
                }
            }
            GridRow {
                label(String(localized: "machines.new.kind.label", defaultValue: "Kind"))
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $model.kind) {
                        ForEach(model.selectableKinds, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("NewMachineSheet.kind")
                    Text(model.kind.summary)
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
            Text(model.isBaseSetup
                ? String(localized: "machines.new.background.note.base", defaultValue: "Setup continues in the Machines panel.")
                : String(localized: "machines.new.background.note", defaultValue: "Creation continues in the Machines panel."))
                .cmuxFont(size: 11)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .accessibilityIdentifier("NewMachineSheet.backgroundNote")
            Spacer()
            Button(String(localized: "machines.new.cancel", defaultValue: "Cancel")) {
                model.cancel()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("NewMachineSheet.cancel")
            Button(createTitle) {
                model.create()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("NewMachineSheet.create")
        }
    }

    private var createTitle: String {
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
