import AppKit
import CmuxSettings
import SwiftUI

@MainActor
struct InterfaceAppearanceCards: View {
    @State private var colorsJSON: DefaultsValueModel<String>
    @State private var iconsJSON: DefaultsValueModel<String>

    init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _colorsJSON = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.interfaceAppearance.colorsJSON))
        _iconsJSON = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.interfaceAppearance.iconsJSON))
    }

    var body: some View {
        InterfaceColorCard(
            colors: Self.decode(colorsJSON.current),
            revision: colorsJSON.revision,
            save: { colorsJSON.set(Self.encode($0)) }
        )
        .settingsSearchAnchors(["setting:workspaceColors:interface-colors"])
        InterfaceIconCard(
            icons: Self.decode(iconsJSON.current),
            save: { iconsJSON.set(Self.encode($0)) }
        )
        .settingsSearchAnchors(["setting:workspaceColors:interface-icons"])
        .task {
            colorsJSON.startObserving()
            iconsJSON.startObserving()
        }
    }

    static func decode(_ rawValue: String) -> [String: String] {
        guard let data = rawValue.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let map = object as? [String: String] else { return [:] }
        return map
    }

    static func encode(_ map: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }
}

private struct InterfaceColorDefinition: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let fallback: NSColor

    static let all: [Self] = [
        .init(id: "accent", title: String(localized: "settings.appearance.color.accent", defaultValue: "Accent"), subtitle: String(localized: "settings.appearance.color.accent.subtitle", defaultValue: "Progress indicators and cmux accent controls."), fallback: .controlAccentColor),
        .init(id: "hover", title: String(localized: "settings.appearance.color.hover", defaultValue: "Hover Highlight"), subtitle: String(localized: "settings.appearance.color.hover.subtitle", defaultValue: "Pointer hover fills on cmux-owned controls."), fallback: .controlAccentColor),
        .init(id: "dropTarget", title: String(localized: "settings.appearance.color.dropTarget", defaultValue: "Drag and Drop Target"), subtitle: String(localized: "settings.appearance.color.dropTarget.subtitle", defaultValue: "Bonsplit pane targets, tab insertion, and drop outlines."), fallback: .controlAccentColor),
        .init(id: "notification", title: String(localized: "settings.appearance.color.notification", defaultValue: "Notification Ring"), subtitle: String(localized: "settings.appearance.color.notification.subtitle", defaultValue: "Pane attention rings and notification emphasis."), fallback: .systemBlue),
        .init(id: "success", title: String(localized: "settings.appearance.color.success", defaultValue: "Success"), subtitle: String(localized: "settings.appearance.color.success.subtitle", defaultValue: "Successful task and status indicators."), fallback: .systemGreen),
        .init(id: "warning", title: String(localized: "settings.appearance.color.warning", defaultValue: "Warning"), subtitle: String(localized: "settings.appearance.color.warning.subtitle", defaultValue: "Warning task and status indicators."), fallback: .systemOrange),
        .init(id: "error", title: String(localized: "settings.appearance.color.error", defaultValue: "Error"), subtitle: String(localized: "settings.appearance.color.error.subtitle", defaultValue: "Failed task and error indicators."), fallback: .systemRed),
        .init(id: "toolbarIcon", title: String(localized: "settings.appearance.color.toolbarIcon", defaultValue: "Toolbar Icons"), subtitle: String(localized: "settings.appearance.color.toolbarIcon.subtitle", defaultValue: "cmux titlebar and sidebar action symbols."), fallback: .labelColor),
        .init(id: "tabIcon", title: String(localized: "settings.appearance.color.tabIcon", defaultValue: "Pane Tab Icons"), subtitle: String(localized: "settings.appearance.color.tabIcon.subtitle", defaultValue: "Terminal, browser, and file pane symbols."), fallback: .labelColor),
    ]
}

@MainActor
private struct InterfaceColorCard: View {
    let colors: [String: String]
    let revision: Int
    let save: ([String: String]) -> Void

    var body: some View {
        SettingsCard {
            SettingsCardNote(String(localized: "settings.appearance.colors.note", defaultValue: "These colors affect cmux chrome. Terminal palette colors remain controlled by Ghostty config."))
            ForEach(Array(InterfaceColorDefinition.all.enumerated()), id: \.element.id) { index, definition in
                if index > 0 { SettingsCardDivider() }
                InterfaceColorRow(
                    definition: definition,
                    storedHex: colors[definition.id],
                    revision: revision,
                    set: { value in
                        var next = colors
                        if let value { next[definition.id] = value } else { next.removeValue(forKey: definition.id) }
                        save(next)
                    }
                )
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .action,
                String(localized: "settings.appearance.colors.reset", defaultValue: "Reset Interface Colors"),
                subtitle: String(localized: "settings.appearance.colors.reset.subtitle", defaultValue: "Restore native colors for every cmux chrome role.")
            ) {
                Button(String(localized: "settings.workspaceColors.resetPalette.button", defaultValue: "Reset")) { save([:]) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(colors.isEmpty)
            }
        }
    }
}

@MainActor
private struct InterfaceColorRow: View {
    let definition: InterfaceColorDefinition
    let storedHex: String?
    let revision: Int
    let set: (String?) -> Void

    var body: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            definition.title,
            subtitle: definition.subtitle
        ) {
            HStack(spacing: 8) {
                if storedHex != nil {
                    Button(String(localized: "settings.workspaceColors.selectionColor.reset", defaultValue: "Reset")) { set(nil) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                HexColorPicker(
                    storedHex: storedHex ?? Color(nsColor: definition.fallback).cmuxHexString,
                    fallback: Color(nsColor: definition.fallback),
                    reconcileRevision: revision
                ) { set($0) }
                Text(storedHex ?? String(localized: "settings.sidebarAppearance.defaultLabel", defaultValue: "Default"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
            }
        }
    }
}

private struct InterfaceIconDefinition: Identifiable {
    let id: String
    let title: String

    static let common: [Self] = [
        .init(id: "plus", title: String(localized: "settings.appearance.icon.add", defaultValue: "Add")),
        .init(id: "bell", title: String(localized: "settings.appearance.icon.notifications", defaultValue: "Notifications")),
        .init(id: "gearshape", title: String(localized: "settings.appearance.icon.settings", defaultValue: "Settings")),
        .init(id: "pin.fill", title: String(localized: "settings.appearance.icon.pin", defaultValue: "Pinned")),
        .init(id: "xmark", title: String(localized: "settings.appearance.icon.close", defaultValue: "Close")),
        .init(id: "terminal", title: String(localized: "settings.appearance.icon.terminal", defaultValue: "Terminal")),
        .init(id: "globe", title: String(localized: "settings.appearance.icon.browser", defaultValue: "Browser")),
        .init(id: "square.split.2x1", title: String(localized: "settings.appearance.icon.splitRight", defaultValue: "Split Right")),
        .init(id: "square.split.1x2", title: String(localized: "settings.appearance.icon.splitDown", defaultValue: "Split Down")),
        .init(id: "sidebar.left", title: String(localized: "settings.appearance.icon.sidebar", defaultValue: "Sidebar")),
        .init(id: "folder.fill", title: String(localized: "settings.appearance.icon.workspaceGroup", defaultValue: "Workspace Group")),
        .init(id: "doc.text", title: String(localized: "settings.appearance.icon.genericPane", defaultValue: "Generic Pane")),
    ]
}

@MainActor
private struct InterfaceIconCard: View {
    let icons: [String: String]
    let save: ([String: String]) -> Void
    @State private var original = ""
    @State private var replacement = ""

    private var commonNames: Set<String> { Set(InterfaceIconDefinition.common.map(\.id)) }
    private var customEntries: [(String, String)] {
        icons.filter { !commonNames.contains($0.key) }.sorted { $0.key < $1.key }
    }

    var body: some View {
        SettingsCard {
            SettingsCardNote(String(localized: "settings.appearance.icons.note", defaultValue: "Map any SF Symbol rendered by cmux to another valid SF Symbol."))
            ForEach(Array(InterfaceIconDefinition.common.enumerated()), id: \.element.id) { index, definition in
                if index > 0 { SettingsCardDivider() }
                InterfaceIconRow(
                    title: definition.title,
                    original: definition.id,
                    replacement: icons[definition.id],
                    save: saveReplacement
                )
            }
            ForEach(customEntries, id: \.0) { entry in
                SettingsCardDivider()
                InterfaceIconRow(title: entry.0, original: entry.0, replacement: entry.1, save: saveReplacement)
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.appearance.icons.addOverride", defaultValue: "Add Icon Override"),
                subtitle: String(localized: "settings.appearance.icons.addOverride.subtitle", defaultValue: "Enter the original and replacement SF Symbol names.")
            ) {
                HStack(spacing: 6) {
                    TextField(String(localized: "settings.appearance.icons.original", defaultValue: "Original"), text: $original)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 125)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "settings.appearance.icons.replacement", defaultValue: "Replacement"), text: $replacement)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 125)
                    Button(String(localized: "settings.appearance.icons.add", defaultValue: "Add")) { addCustom() }
                        .disabled(!canAddCustom)
                }
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .action,
                String(localized: "settings.appearance.icons.reset", defaultValue: "Reset All Icons")
            ) {
                Button(String(localized: "settings.workspaceColors.resetPalette.button", defaultValue: "Reset")) { save([:]) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(icons.isEmpty)
            }
        }
    }

    private var canAddCustom: Bool {
        NSImage(systemSymbolName: original, accessibilityDescription: nil) != nil &&
            NSImage(systemSymbolName: replacement, accessibilityDescription: nil) != nil
    }

    private func addCustom() {
        saveReplacement(original, replacement)
        original = ""
        replacement = ""
    }

    private func saveReplacement(_ original: String, _ replacement: String?) {
        var next = icons
        if let replacement, !replacement.isEmpty { next[original] = replacement } else { next.removeValue(forKey: original) }
        save(next)
    }
}

@MainActor
private struct InterfaceIconRow: View {
    let title: String
    let original: String
    let replacement: String?
    let save: (String, String?) -> Void
    @State private var draft = ""

    var body: some View {
        SettingsCardRow(configurationReview: .settingsOnly, title, subtitle: original) {
            HStack(spacing: 8) {
                Image(systemName: replacement ?? original)
                    .frame(width: 20)
                TextField(original, text: Binding(
                    get: { draft.isEmpty ? (replacement ?? "") : draft },
                    set: { value in draft = value; if NSImage(systemSymbolName: value, accessibilityDescription: nil) != nil { save(original, value); draft = "" } }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                if replacement != nil {
                    Button(String(localized: "settings.workspaceColors.remove", defaultValue: "Remove")) { save(original, nil) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}
