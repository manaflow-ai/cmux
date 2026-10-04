import CmuxNextDesign
import SwiftUI

/// Appearance: pick the room, workspace or terminal theme of the window
/// Settings was opened from, from every Ghostty theme with type-to-search.
/// Typed text that is a valid spec but not a listed name (a light/dark pair,
/// a path) gets its own row. Choosing runs the theme actions (host). Each
/// theme row leads with its swatch strip (R98), from the App's cache.
struct ThemePickerCard: View {
    let model: SettingsWindowModel
    @State private var level: SettingsThemeLevel = .room
    @State private var query = ""
    /// Bumped after a choice so the checkmark re-reads the host.
    @State private var revision = 0

    var body: some View {
        if let host = model.host, !host.themeLevels.isEmpty {
            SettingsCard(title: SettingsWindowStrings.themePickerTitle) {
                VStack(alignment: .leading, spacing: Metrics.space3) {
                    Picker("", selection: $level) {
                        ForEach(host.themeLevels) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    TextField(SettingsWindowStrings.themeSearch, text: $query)
                        .textFieldStyle(.roundedBorder)
                        .font(SettingsStyle.body)
                    rows(host)
                }
                .padding(.horizontal, Metrics.space5)
                .padding(.vertical, Metrics.space2)
            }
            .onAppear { if !host.themeLevels.contains(level) { level = host.themeLevels[0] } }
        }
    }

    private func rows(_ host: any SettingsWindowHost) -> some View {
        let current = revision >= 0 ? host.theme(at: level) : nil
        let text = query.trimmingCharacters(in: .whitespaces)
        let names = text.isEmpty ? host.themeNames : host.themeNames.filter { $0.localizedCaseInsensitiveContains(text) }
        let custom = !text.isEmpty && !host.themeNames.contains(text) && host.acceptsTheme(text) ? text : nil
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                row(SettingsWindowStrings.themeUseConfig, selected: current == nil) { choose(nil, host) }
                if let custom {
                    row(SettingsWindowStrings.themeUse(custom), selected: current == custom) { choose(custom, host) }
                }
                ForEach(names, id: \.self) { name in
                    row(name, swatches: host.themeSwatches(name), selected: current == name) { choose(name, host) }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeFade()
        .frame(height: 240)
    }

    private func row(_ title: String, swatches: [ThemeRGB] = [], selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                ThemeSwatchStrip(colors: swatches)
                Text(title).font(SettingsStyle.body).foregroundStyle(SettingsStyle.text)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").foregroundStyle(SettingsStyle.secondary) }
            }
            .padding(.horizontal, Metrics.space2)
            .frame(height: SettingsStyle.rowHeight)
            .background(selected ? SettingsStyle.selection : .clear, in: RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ spec: String?, _ host: any SettingsWindowHost) {
        host.setTheme(spec, at: level)
        revision += 1
    }
}
