import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Inline VS Code** section — controls how the built-in "Open Current
/// Directory in VS Code (Inline)" command launches VS Code's `serve-web`:
/// persistent state, the local port, the server data directory, and any extra
/// upstream `serve-web` flags. All four keys are JSON-backed (`inlineVSCode.*`
/// in `~/.config/cmux/cmux.json`); the macOS app reads them when inline VS Code
/// (re)starts.
@MainActor
public struct InlineVSCodeSection: View {
    @State private var persist: JSONValueModel<Bool>
    @State private var port: JSONValueModel<Int>
    @State private var serverDataDir: JSONValueModel<String>
    @State private var extraArgs: JSONValueModel<[String]>

    @State private var portDraft: String = ""
    @State private var portLoaded: Bool = false
    @State private var serverDataDirDraft: String = ""
    @State private var serverDataDirLoaded: Bool = false
    @State private var extraArgsDraft: String = ""
    @State private var extraArgsLoaded: Bool = false
    @FocusState private var extraArgsFocused: Bool

    public init(
        jsonStore: JSONConfigStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog
    ) {
        _persist = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.inlineVSCode.persistServeWebState,
            errorLog: errorLog
        ))
        _port = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.inlineVSCode.port,
            errorLog: errorLog
        ))
        _serverDataDir = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.inlineVSCode.serverDataDir,
            errorLog: errorLog
        ))
        _extraArgs = State(initialValue: JSONValueModel(
            store: jsonStore,
            key: catalog.inlineVSCode.extraArgs,
            errorLog: errorLog
        ))
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.inlineVSCode", defaultValue: "Inline VS Code"),
                section: .inlineVSCode
            )
            SettingsCard {
                persistRow
                SettingsCardDivider()
                portRow
                SettingsCardDivider()
                serverDataDirRow
                SettingsCardDivider()
                extraArgsRow
                SettingsCardDivider()
                SettingsCardNote(String(
                    localized: "settings.inlineVSCode.note",
                    defaultValue: "These options apply when you run \"Open Current Directory in VS Code (Inline)\". Changes take effect the next time inline VS Code starts — use \"Restart Inline VS Code\" to apply them now. cmux always binds serve-web to 127.0.0.1 with a connection token; extra arguments are advanced and unsupported."
                ))
            }
        }
        .task { startObservingSettings() }
        .onChange(of: port.current) { _, newValue in
            let normalized = Self.portText(newValue)
            if Self.parsePort(portDraft) != newValue {
                portDraft = normalized
            }
        }
        .onChange(of: serverDataDir.current) { _, newValue in
            if serverDataDirDraft != newValue {
                serverDataDirDraft = newValue
            }
        }
        .onChange(of: extraArgs.current) { _, newValue in
            if Self.parseExtraArgs(extraArgsDraft) != newValue {
                extraArgsDraft = newValue.joined(separator: "\n")
            }
        }
        .onChange(of: extraArgsFocused) { _, isFocused in
            if !isFocused {
                commitExtraArgs()
            }
        }
    }

    private func startObservingSettings() {
        let models: [any SettingObservationStarting] = [persist, port, serverDataDir, extraArgs]
        models.forEach { $0.startObserving() }
        if !portLoaded {
            portDraft = Self.portText(port.current)
            portLoaded = true
        }
        if !serverDataDirLoaded {
            serverDataDirDraft = serverDataDir.current
            serverDataDirLoaded = true
        }
        if !extraArgsLoaded {
            extraArgsDraft = extraArgs.current.joined(separator: "\n")
            extraArgsLoaded = true
        }
    }

    @ViewBuilder
    private var persistRow: some View {
        SettingsCardRow(
            configurationReview: .json("inlineVSCode.persistServeWebState"),
            String(localized: "settings.inlineVSCode.persistState", defaultValue: "Persist serve-web State"),
            subtitle: persist.current
                ? String(localized: "settings.inlineVSCode.persistState.subtitleOn", defaultValue: "Keeps sign-in and Settings Sync state across restarts.")
                : String(localized: "settings.inlineVSCode.persistState.subtitleOff", defaultValue: "Uses a throwaway data directory; nothing persists between launches.")
        ) {
            Toggle("", isOn: Binding(get: { persist.current }, set: { persist.set($0) }))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsInlineVSCodePersistToggle")
        }
    }

    @ViewBuilder
    private var portRow: some View {
        SettingsCardRow(
            configurationReview: .json("inlineVSCode.port"),
            String(localized: "settings.inlineVSCode.port", defaultValue: "Port"),
            subtitle: String(localized: "settings.inlineVSCode.port.subtitle", defaultValue: "Local serve-web port. Leave empty (or 0) to pick a random free port. Range 1–65535."),
            controlWidth: 120
        ) {
            TextField(
                String(localized: "settings.inlineVSCode.port.placeholder", defaultValue: "random"),
                text: $portDraft,
                onCommit: { commitPort() }
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .accessibilityIdentifier("SettingsInlineVSCodePortField")
        }
    }

    @ViewBuilder
    private var serverDataDirRow: some View {
        SettingsCardRow(
            configurationReview: .json("inlineVSCode.serverDataDir"),
            String(localized: "settings.inlineVSCode.serverDataDir", defaultValue: "Server Data Directory"),
            subtitle: String(localized: "settings.inlineVSCode.serverDataDir.subtitle", defaultValue: "serve-web --server-data-dir. Leave empty to use the VS Code default. A leading ~ expands to your home directory."),
            controlWidth: 240
        ) {
            TextField(
                String(localized: "settings.inlineVSCode.serverDataDir.placeholder", defaultValue: "e.g. ~/Library/Application Support/cmux/vscode-serve-web"),
                text: $serverDataDirDraft,
                onCommit: { serverDataDir.set(serverDataDirDraft.trimmingCharacters(in: .whitespacesAndNewlines)) }
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("SettingsInlineVSCodeServerDataDirField")
        }
    }

    @ViewBuilder
    private var extraArgsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCardRow(
                configurationReview: .json("inlineVSCode.extraArgs"),
                String(localized: "settings.inlineVSCode.extraArgs", defaultValue: "Extra serve-web Arguments"),
                subtitle: String(localized: "settings.inlineVSCode.extraArgs.subtitle", defaultValue: "Advanced upstream VS Code serve-web flags, one per line. cmux-managed flags (host, port, connection token, server data dir) are ignored.")
            ) {
                EmptyView()
            }
            TextEditor(text: $extraArgsDraft)
                .focused($extraArgsFocused)
                .cmuxFont(.body, design: .monospaced)
                .frame(minHeight: 56, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .accessibilityIdentifier("SettingsInlineVSCodeExtraArgsEditor")
        }
    }

    private func commitPort() {
        port.set(Self.parsePort(portDraft))
        portDraft = Self.portText(Self.parsePort(portDraft))
    }

    private func commitExtraArgs() {
        let parsed = Self.parseExtraArgs(extraArgsDraft)
        if parsed != extraArgs.current {
            extraArgs.set(parsed)
        }
    }

    /// Parses the port draft, clamping to the valid `serve-web` range. Empty or
    /// out-of-range input resolves to `0` (a random free port).
    static func parsePort(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (0...65535).contains(value) else { return 0 }
        return value
    }

    /// Renders a stored port for the text field: `0` shows as empty (random).
    static func portText(_ port: Int) -> String {
        port == 0 ? "" : String(port)
    }

    /// Splits the multi-line draft into one argument per non-empty trimmed line.
    static func parseExtraArgs(_ text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
