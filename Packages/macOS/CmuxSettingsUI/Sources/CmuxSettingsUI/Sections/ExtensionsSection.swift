import SwiftUI

/// **Extensions** section — Dock TUI extensions installed from GitHub:
/// an install field, a marketplace link, and the installed list with
/// open/enable/update/uninstall controls. All data and actions come from the
/// host via ``ExtensionsSettingsState`` (value snapshots + closures).
@MainActor
public struct ExtensionsSection: View {
    private let state: ExtensionsSettingsState?
    @State private var installInput = ""
    @State private var pendingUninstall: ExtensionsSettingsState.Row?

    public init(hostActions: SettingsHostActions) {
        self.state = hostActions.dockExtensionsSettingsState()
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(
                String(localized: "settings.section.extensions", defaultValue: "Extensions"),
                section: .extensions
            )
            card
        }
    }

    // The modifiers live on the card (not the transparent Group) so the task
    // and the dialog presentation attach exactly once.
    private var card: some View {
        SettingsCard {
            if let state {
                content(state)
            } else {
                SettingsCardNote(
                    String(
                        localized: "settings.extensions.unavailable",
                        defaultValue: "Extensions are unavailable in this context."
                    )
                )
            }
        }
        .task { state?.actions.refresh() }
        .confirmationDialog(
            String(
                localized: "settings.extensions.uninstall.title",
                defaultValue: "Uninstall \(pendingUninstall?.displayName ?? "")?"
            ),
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "settings.extensions.uninstall.confirm", defaultValue: "Uninstall"),
                role: .destructive
            ) {
                if let row = pendingUninstall {
                    state?.actions.uninstall(row.id)
                }
                pendingUninstall = nil
            }
        } message: {
            Text(String(
                localized: "settings.extensions.uninstall.message",
                defaultValue: "Removes the extension and its checkout. Its config and state directories are kept."
            ))
        }
    }

    @ViewBuilder
    private func content(_ state: ExtensionsSettingsState) -> some View {
        SettingsCardNote(
            String(
                localized: "settings.extensions.note",
                defaultValue: "Extensions are TUI apps published on GitHub that run inside the Dock. They are not reviewed by cmux and run as you, with your environment — install only from authors you trust. Installing pins the extension to a commit and enables the Dock beta feature."
            )
        )
        SettingsCardDivider()
        installRow(state)
        SettingsCardDivider()
        marketplaceRow(state)
        if state.rows.isEmpty {
            SettingsCardDivider()
            SettingsCardNote(
                String(
                    localized: "settings.extensions.empty",
                    defaultValue: "No extensions installed."
                )
            )
        } else {
            ForEach(state.rows) { row in
                SettingsCardDivider()
                extensionRow(row, state: state)
            }
        }
        if let message = state.lastErrorMessage, !message.isEmpty {
            SettingsCardDivider()
            SettingsCardNote(message)
        }
    }

    @ViewBuilder
    private func installRow(_ state: ExtensionsSettingsState) -> some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:extensions:install",
            String(localized: "settings.extensions.install", defaultValue: "Install from GitHub"),
            subtitle: String(
                localized: "settings.extensions.install.subtitle",
                defaultValue: "owner/repo or owner/repo/subdirectory. You review the exact commands before anything runs."
            )
        ) {
            HStack(spacing: 6) {
                TextField(
                    String(localized: "settings.extensions.install.placeholder", defaultValue: "owner/repo"),
                    text: $installInput
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 190)
                .accessibilityIdentifier("SettingsExtensionsInstallField")
                .onSubmit { submitInstall(state) }
                Button(String(localized: "settings.extensions.install.button", defaultValue: "Install…")) {
                    submitInstall(state)
                }
                .controlSize(.small)
                .disabled(installInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("SettingsExtensionsInstallButton")
            }
        }
    }

    @ViewBuilder
    private func marketplaceRow(_ state: ExtensionsSettingsState) -> some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:extensions:marketplace",
            String(localized: "settings.extensions.marketplace", defaultValue: "Marketplace"),
            subtitle: String(
                localized: "settings.extensions.marketplace.subtitle",
                defaultValue: "Community extensions: public GitHub repositories tagged cmux-extension."
            )
        ) {
            Button(String(localized: "settings.extensions.marketplace.button", defaultValue: "Browse…")) {
                state.actions.browseMarketplace()
            }
            .controlSize(.small)
            .accessibilityIdentifier("SettingsExtensionsBrowseButton")
        }
    }

    @ViewBuilder
    private func extensionRow(_ row: ExtensionsSettingsState.Row, state: ExtensionsSettingsState) -> some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            searchAnchorID: "setting:extensions:installed:\(row.id)",
            rowTitle(row),
            subtitle: rowSubtitle(row)
        ) {
            HStack(spacing: 8) {
                openControl(row, state: state)
                Toggle("", isOn: Binding(
                    get: { row.enabled },
                    set: { state.actions.setEnabled(row.id, $0) }
                ))
                .labelsHidden()
                .controlSize(.small)
                .disabled(row.isBusy)
                .accessibilityIdentifier("SettingsExtensionEnabledToggle-\(row.id)")
                rowMenu(row, state: state)
            }
        }
    }

    @ViewBuilder
    private func openControl(_ row: ExtensionsSettingsState.Row, state: ExtensionsSettingsState) -> some View {
        let openTitle = String(localized: "settings.extensions.open", defaultValue: "Open")
        if row.panes.count == 1, let pane = row.panes.first {
            Button {
                state.actions.openPane(pane.id)
            } label: {
                Label(openTitle, systemImage: row.iconSystemName)
            }
            .controlSize(.small)
            .disabled(row.isBusy)
        } else if row.panes.count > 1 {
            Menu {
                ForEach(row.panes) { pane in
                    Button(pane.title) { state.actions.openPane(pane.id) }
                }
            } label: {
                Label(openTitle, systemImage: row.iconSystemName)
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(row.isBusy)
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: ExtensionsSettingsState.Row, state: ExtensionsSettingsState) -> some View {
        Menu {
            if !row.isLinked {
                Button(String(localized: "settings.extensions.update", defaultValue: "Check for Update…")) {
                    state.actions.update(row.id)
                }
            }
            if let repoURL = row.repoURL {
                Link(
                    String(localized: "settings.extensions.viewOnGitHub", defaultValue: "View on GitHub"),
                    destination: repoURL
                )
            }
            Divider()
            Button(
                String(localized: "settings.extensions.uninstall", defaultValue: "Uninstall…"),
                role: .destructive
            ) {
                pendingUninstall = row
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(row.isBusy)
        .accessibilityIdentifier("SettingsExtensionMenu-\(row.id)")
    }

    private func rowTitle(_ row: ExtensionsSettingsState.Row) -> String {
        if let version = row.version, !version.isEmpty {
            return "\(row.displayName) \(version)"
        }
        return row.displayName
    }

    private func rowSubtitle(_ row: ExtensionsSettingsState.Row) -> String {
        var parts: [String] = [row.sourceLabel]
        if !row.detail.isEmpty { parts.append(row.detail) }
        if let statusMessage = row.statusMessage, !statusMessage.isEmpty {
            parts.append(statusMessage)
        }
        return parts.joined(separator: " · ")
    }

    private func submitInstall(_ state: ExtensionsSettingsState) {
        let input = installInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        state.actions.installFromInput(input)
        installInput = ""
    }
}
