import CmuxNextDesign
import CmuxNextSettings
import SwiftUI

/// A web address field, written on Return or when it loses focus.
struct AddressControl: View {
    let model: SettingsWindowModel
    let descriptor: SettingDescriptor
    @State private var text: String?
    @FocusState private var focused: Bool

    var body: some View {
        let stored = model.value(descriptor)?.stringValue ?? ""
        let binding = Binding<String>(get: { text ?? stored }, set: { text = $0 })
        let valid = descriptor.accepts(.string(binding.wrappedValue))
        TextField(SettingsWindowStrings.blankPage, text: binding)
            .textFieldStyle(.roundedBorder)
            .frame(width: Metrics.sidebarWidth)
            .focused($focused)
            .foregroundStyle(valid ? SettingsStyle.text : SettingsStyle.danger)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        guard let text else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard descriptor.accepts(.string(trimmed)) else { return }
        model.set(descriptor, trimmed.isEmpty ? nil : .string(trimmed))
        self.text = nil
    }
}

/// Hosts as removable chips plus a field to add one.
struct HostListControl: View {
    let model: SettingsWindowModel
    let descriptor: SettingDescriptor
    @State private var draft = ""

    var body: some View {
        let hosts = (model.value(descriptor)?.arrayValue ?? []).compactMap(\.stringValue)
        VStack(alignment: .trailing, spacing: Metrics.space2) {
            ForEach(hosts, id: \.self) { host in
                HStack(spacing: Metrics.space2) {
                    Text(host).font(SettingsStyle.keycap)
                    Button { write(hosts.filter { $0 != host }) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(SettingsStyle.secondary).help(SettingsWindowStrings.remove)
                }
            }
            HStack(spacing: Metrics.space2) {
                TextField(SettingsWindowStrings.hostPlaceholder, text: $draft)
                    .textFieldStyle(.roundedBorder).frame(width: Metrics.sidebarWidth * 0.75)
                    .onSubmit(add)
                Button {
                    add()
                } label: {
                    Text(SettingsWindowStrings.add).fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let host = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty else { return }
        let hosts = (model.value(descriptor)?.arrayValue ?? []).compactMap(\.stringValue)
        if !hosts.contains(host) { write(hosts + [host]) }
        draft = ""
    }

    private func write(_ hosts: [String]) {
        model.set(descriptor, hosts.isEmpty ? nil : .array(hosts.map(JSONValue.string)))
    }
}

/// Quiet hours: off, or a daily window.
struct TimeRangeControl: View {
    let model: SettingsWindowModel
    let descriptor: SettingDescriptor

    var body: some View {
        let range = model.value(descriptor)?.objectValue
        HStack(spacing: Metrics.space3) {
            if let range {
                Text(SettingsWindowStrings.quietFrom).foregroundStyle(SettingsStyle.secondary)
                time(range["start"]?.stringValue ?? "22:00") { write(start: $0, end: range["end"]?.stringValue ?? "08:00") }
                Text(SettingsWindowStrings.quietTo).foregroundStyle(SettingsStyle.secondary)
                time(range["end"]?.stringValue ?? "08:00") { write(start: range["start"]?.stringValue ?? "22:00", end: $0) }
            }
            Toggle("", isOn: Binding(get: { range != nil }, set: { on in
                on ? write(start: "22:00", end: "08:00") : model.set(descriptor, nil)
            })).labelsHidden().toggleStyle(.switch)
        }
    }

    private func write(start: String, end: String) {
        model.set(descriptor, .object(["start": .string(start), "end": .string(end)]))
    }

    private func time(_ text: String, set: @escaping (String) -> Void) -> some View {
        let minutes = QuietHours.minutes(text) ?? 0
        let calendar = Calendar.current
        let date = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date(timeIntervalSinceReferenceDate: 0)) ?? Date()
        return DatePicker("", selection: Binding(get: { date }, set: { newValue in
            let parts = calendar.dateComponents([.hour, .minute], from: newValue)
            set(String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0))
        }), displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
    }
}
