import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Workspace Colors** section.
///
/// Hosts the active-workspace indicator style, selection / badge
/// color overrides, and a named-palette editor that lets users add,
/// edit, or remove custom workspace colors. Palette mutations are
/// persisted to the JSON-config-backed
/// ``WorkspaceColorsCatalogSection/customColors`` and
/// ``WorkspaceColorsCatalogSection/paletteOverrides`` so they sync
/// across devices through cmux.json.
@MainActor
public struct WorkspaceColorsSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog
    private let errorLog: SettingsErrorLog?

    @State private var customColors: [String] = []
    @State private var paletteOverrides: [String: String] = [:]
    @State private var streamTask: Task<Void, Never>?
    @State private var overridesTask: Task<Void, Never>?
    @State private var newColorDraft: String = "#"

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog? = nil
    ) {
        self.defaultsStore = defaultsStore
        self.jsonStore = jsonStore
        self.catalog = catalog
        self.errorLog = errorLog
    }

    public var body: some View {
        Form {
            Section("Indicator") {
                SettingsPickerRow(
                    model: DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.indicatorStyle),
                    title: "Active-workspace indicator",
                    label: { style in
                        switch style {
                        case .leftRail: return "Left rail"
                        case .solidFill: return "Solid fill"
                        }
                    }
                )
            }
            Section("Colors") {
                hexRowWithReset(title: "Selection color (#RRGGBB)", key: catalog.workspaceColors.selectionColorHex)
                hexRowWithReset(title: "Notification badge color (#RRGGBB)", key: catalog.workspaceColors.notificationBadgeColorHex)
            }
            Section("Custom Palette") {
                Text("Add custom workspace colors as hex strings. They appear alongside the built-in palette in the workspace settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(customColors.enumerated()), id: \.offset) { index, hex in
                    customColorRow(hex: hex, index: index)
                }
                HStack {
                    TextField("#RRGGBB", text: $newColorDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                    Button("Add") {
                        addCustomColor()
                    }
                    .disabled(!isValidHex(newColorDraft))
                }
            }
            Section("Palette Overrides") {
                Text("Override the hex value cmux uses for a named built-in color. Format: enter the palette name and the new hex value.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(paletteOverrides.keys.sorted()), id: \.self) { name in
                    overrideRow(name: name)
                }
                addOverrideRow
            }
        }
        .formStyle(.grouped)
        .task {
            await observeCustomColors()
        }
        .task {
            await observeOverrides()
        }
        .onDisappear {
            streamTask?.cancel()
            overridesTask?.cancel()
        }
    }

    @ViewBuilder
    private func hexRow(title: String, key: DefaultsKey<String>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        TextField(title, text: Binding(
            get: { model.current },
            set: { model.set($0) }
        ))
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private func hexRowWithReset(title: String, key: DefaultsKey<String>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        HStack {
            TextField(title, text: Binding(
                get: { model.current },
                set: { model.set($0) }
            ))
            .textFieldStyle(.roundedBorder)
            Button("Reset") {
                model.reset()
            }
            .disabled(model.current == key.defaultValue)
        }
    }

    @ViewBuilder
    private func customColorRow(hex: String, index: Int) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(colorFromHex(hex) ?? Color.gray)
                .frame(width: 22, height: 22)
            Text(hex)
                .font(.system(.body, design: .monospaced))
            Spacer()
            Button(role: .destructive) {
                removeCustomColor(at: index)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    @State private var newOverrideName: String = ""
    @State private var newOverrideValue: String = "#"

    @ViewBuilder
    private var addOverrideRow: some View {
        HStack {
            TextField("Name", text: $newOverrideName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
            TextField("#RRGGBB", text: $newOverrideValue)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
            Button("Add Override") {
                addOverride()
            }
            .disabled(newOverrideName.isEmpty || !isValidHex(newOverrideValue))
        }
    }

    @ViewBuilder
    private func overrideRow(name: String) -> some View {
        HStack {
            Text(name)
                .frame(maxWidth: 120, alignment: .leading)
            TextField("#RRGGBB", text: Binding(
                get: { paletteOverrides[name] ?? "" },
                set: { newValue in
                    paletteOverrides[name] = newValue
                    persistOverrides()
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 120)
            Spacer()
            Button(role: .destructive) {
                paletteOverrides.removeValue(forKey: name)
                persistOverrides()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func addCustomColor() {
        guard isValidHex(newColorDraft) else { return }
        var updated = customColors
        if !updated.contains(newColorDraft) {
            updated.append(newColorDraft)
        }
        customColors = updated
        persistCustomColors()
        newColorDraft = "#"
    }

    private func removeCustomColor(at index: Int) {
        guard customColors.indices.contains(index) else { return }
        customColors.remove(at: index)
        persistCustomColors()
    }

    private func addOverride() {
        guard !newOverrideName.isEmpty, isValidHex(newOverrideValue) else { return }
        paletteOverrides[newOverrideName] = newOverrideValue
        persistOverrides()
        newOverrideName = ""
        newOverrideValue = "#"
    }

    private func observeCustomColors() async {
        streamTask?.cancel()
        let task = Task {
            for await value in jsonStore.values(for: catalog.workspaceColors.customColors) {
                if Task.isCancelled { break }
                customColors = value
            }
        }
        streamTask = task
        await task.value
    }

    private func observeOverrides() async {
        overridesTask?.cancel()
        let task = Task {
            for await value in jsonStore.values(for: catalog.workspaceColors.paletteOverrides) {
                if Task.isCancelled { break }
                paletteOverrides = value
            }
        }
        overridesTask = task
        await task.value
    }

    private func persistCustomColors() {
        let snapshot = customColors
        Task {
            do {
                try await jsonStore.set(snapshot, for: catalog.workspaceColors.customColors)
            } catch {
                errorLog?.record(error, keyID: catalog.workspaceColors.customColors.id)
            }
        }
    }

    private func persistOverrides() {
        let snapshot = paletteOverrides
        Task {
            do {
                try await jsonStore.set(snapshot, for: catalog.workspaceColors.paletteOverrides)
            } catch {
                errorLog?.record(error, keyID: catalog.workspaceColors.paletteOverrides.id)
            }
        }
    }

    private func isValidHex(_ s: String) -> Bool {
        let trimmed = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard trimmed.count == 6 else { return false }
        return trimmed.allSatisfy { $0.isHexDigit }
    }

    private func colorFromHex(_ hex: String) -> Color? {
        var trimmed = hex
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let intVal = UInt32(trimmed, radix: 16) else { return nil }
        let r = Double((intVal >> 16) & 0xFF) / 255
        let g = Double((intVal >> 8) & 0xFF) / 255
        let b = Double(intVal & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}
