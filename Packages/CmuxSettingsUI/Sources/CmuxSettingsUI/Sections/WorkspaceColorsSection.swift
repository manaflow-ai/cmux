import AppKit
import CmuxSettings
import SwiftUI

/// **Workspace Colors** section.
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
    @State private var newOverrideName: String = ""
    @State private var newOverrideValue: String = "#"

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
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionHeader("Workspace Colors")
            SettingsCard {
                let model = DefaultsValueModel(store: defaultsStore, key: catalog.workspaceColors.indicatorStyle)
                SettingsCardRow(
                    configurationReview: .json("workspaceColors.indicatorStyle"),
                    "Active-workspace Indicator",
                    controlWidth: 200
                ) {
                    Picker("", selection: Binding(get: { model.current }, set: { model.set($0) })) {
                        Text("Left rail").tag(WorkspaceIndicatorStyle.leftRail)
                        Text("Solid fill").tag(WorkspaceIndicatorStyle.solidFill)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                SettingsCardDivider()
                hexRowWithReset("Selection Color (#RRGGBB)",
                    json: "workspaceColors.selectionColor",
                    key: catalog.workspaceColors.selectionColorHex)
                SettingsCardDivider()
                hexRowWithReset("Notification Badge Color (#RRGGBB)",
                    json: "workspaceColors.notificationBadgeColor",
                    key: catalog.workspaceColors.notificationBadgeColorHex)
            }

            SettingsSectionHeader("Custom Palette")
            SettingsCard {
                SettingsCardRow(
                    configurationReview: .json("workspaceColors.customColors"),
                    "Custom Colors",
                    subtitle: "Add custom workspace colors as hex strings. They appear alongside the built-in palette."
                ) {
                    EmptyView()
                }
                if !customColors.isEmpty {
                    SettingsCardDivider()
                    ForEach(Array(customColors.enumerated()), id: \.offset) { idx, hex in
                        if idx > 0 { SettingsCardDivider() }
                        customColorRow(hex: hex, index: idx)
                    }
                }
                SettingsCardDivider()
                addCustomRow
            }

            SettingsSectionHeader("Palette Overrides")
            SettingsCard {
                SettingsCardRow(
                    configurationReview: .json("workspaceColors.paletteOverrides"),
                    "Palette Overrides",
                    subtitle: "Override the hex value cmux uses for a named built-in color."
                ) {
                    EmptyView()
                }
                if !paletteOverrides.isEmpty {
                    SettingsCardDivider()
                    ForEach(paletteOverrides.keys.sorted(), id: \.self) { name in
                        overrideRow(name: name)
                        SettingsCardDivider()
                    }
                }
                addOverrideRow
            }
        }
        .task { await observeCustomColors() }
        .task { await observeOverrides() }
        .onDisappear {
            streamTask?.cancel()
            overridesTask?.cancel()
        }
    }

    @ViewBuilder
    private func hexRowWithReset(_ title: String, json: String, key: DefaultsKey<String>) -> some View {
        let model = DefaultsValueModel(store: defaultsStore, key: key)
        SettingsCardRow(configurationReview: .json(json), title, controlWidth: 260) {
            HStack(spacing: 6) {
                TextField("(default)", text: Binding(get: { model.current }, set: { model.set($0) }))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Button("Reset") { model.reset() }
                    .controlSize(.small)
                    .disabled(model.current == key.defaultValue)
            }
        }
    }

    @ViewBuilder
    private func customColorRow(hex: String, index: Int) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(colorFromHex(hex) ?? Color.gray)
                .frame(width: 22, height: 22)
            Text(hex).font(.system(.body, design: .monospaced))
            Spacer()
            Button(role: .destructive) {
                removeCustomColor(at: index)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var addCustomRow: some View {
        HStack {
            TextField("#RRGGBB", text: $newColorDraft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)
                .controlSize(.small)
            Button("Add") { addCustomColor() }
                .disabled(!isValidHex(newColorDraft))
                .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func overrideRow(name: String) -> some View {
        HStack {
            Text(name).frame(maxWidth: 120, alignment: .leading)
            TextField("#RRGGBB", text: Binding(
                get: { paletteOverrides[name] ?? "" },
                set: { newValue in
                    paletteOverrides[name] = newValue
                    persistOverrides()
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 120)
            .controlSize(.small)
            Spacer()
            Button(role: .destructive) {
                paletteOverrides.removeValue(forKey: name)
                persistOverrides()
            } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var addOverrideRow: some View {
        HStack {
            TextField("Name", text: $newOverrideName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
                .controlSize(.small)
            TextField("#RRGGBB", text: $newOverrideValue)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
                .controlSize(.small)
            Button("Add Override") { addOverride() }
                .disabled(newOverrideName.isEmpty || !isValidHex(newOverrideValue))
                .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func addCustomColor() {
        guard isValidHex(newColorDraft) else { return }
        var updated = customColors
        if !updated.contains(newColorDraft) { updated.append(newColorDraft) }
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
            do { try await jsonStore.set(snapshot, for: catalog.workspaceColors.customColors) }
            catch { errorLog?.record(error, keyID: catalog.workspaceColors.customColors.id) }
        }
    }

    private func persistOverrides() {
        let snapshot = paletteOverrides
        Task {
            do { try await jsonStore.set(snapshot, for: catalog.workspaceColors.paletteOverrides) }
            catch { errorLog?.record(error, keyID: catalog.workspaceColors.paletteOverrides.id) }
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
