import CmuxNextDesign
import SwiftUI

/// The Density Lab's middle column: the selected density's name, what its edits do, and every value on a slider.
struct DensityLabControlsView: View {
    @Bindable var model: DensityLabModel
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(DensityLabControl.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.title).font(.headline)
                            ForEach(group.controls) { control in row(control) }
                        }
                    }
                }
                .padding(16)
            }
            .disabled(model.isCapturing)
            Divider()
            footer.padding(16)
        }
        .onAppear { name = model.selected.name }
        .onChange(of: model.selectedID) { name = model.selected.name }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if model.selectedIsBuiltIn {
                    Text(model.selected.name).font(.title2)
                } else {
                    TextField("Name", text: $name).font(.title2).textFieldStyle(.plain)
                        .onSubmit { model.rename(name) }
                }
                Spacer()
                Button("Reset") { model.resetSelected() }
                    .disabled(!model.selectedIsEdited)
                    .help(model.selectedIsBuiltIn ? "Back to the shipped values" : "Back to the values of the built-in it was made from")
            }
            Text(model.selectedIsBuiltIn
                 ? "Built-in. The app shows your changes now; to keep them, save them as your own density."
                 : "Yours. Changes save to cmux.json when you let go of a slider.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ control: DensityLabControl) -> some View {
        let density = model.selected
        let explicit = control.explicitValue(in: density)
        let automatic = control.automaticValue(in: density)
        let shown = explicit ?? automatic ?? control.range.lowerBound
        let isAuto = control.canBeAutomatic && explicit == nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(control.title)
                Spacer()
                if control.canBeAutomatic {
                    Button(isAuto ? "Auto" : "Set") { model.set(control, nil); model.editingEnded() }
                        .buttonStyle(.borderless)
                        .disabled(isAuto)
                        .help(isAuto ? "Follows Size. Move the slider to set it." : "Go back to automatic")
                }
                TextField("", value: Binding(get: { shown }, set: { model.set(control, $0); model.editingEnded() }),
                          format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .foregroundStyle(isAuto ? .secondary : .primary)
                Text(control.unit).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
            }
            Slider(value: Binding(get: { shown }, set: { model.set(control, $0) }), in: control.range,
                   onEditingChanged: { editing in if !editing { model.editingEnded() } })
            .opacity(isAuto ? 0.6 : 1)
            Text(control.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.selectedIsBuiltIn ? "Save as my own density" : "Duplicate") { model.newCustom(name: "\(model.selected.name) copy") }
                    .keyboardShortcut("s")
                if !model.selectedIsBuiltIn {
                    Button("Delete", role: .destructive) { model.deleteSelected() }
                }
            }
            HStack {
                Button("Save built-ins to file") { model.saveBuiltIns() }
                    .help("Writes every built-in as the lab has it to \(model.fileURL.path), to ship as the defaults")
                Button("Copy as preset code") { model.copyPresetCode() }
                    .help("The DensityPreset.tokens switch with the lab's built-ins")
            }
            .disabled(model.editedBuiltInCount == 0)
            Text(model.status.isEmpty ? "\(model.editedBuiltInCount) built-in densities changed in the lab." : model.status)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
