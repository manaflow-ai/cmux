import AppKit
import SwiftUI

struct BrowserExtensionsSettingsRows: View {
    @AppStorage(BrowserExtensionDeveloperModeSettings.key)
    private var browserExtensionsDeveloperMode = BrowserExtensionDeveloperModeSettings.defaultEnabled
    @AppStorage(BrowserExtensionFileURLAccessSettings.key)
    private var browserExtensionsAllowFileURLAccess = BrowserExtensionFileURLAccessSettings.defaultEnabled

    @State private var browserExtensionSummaries: [BrowserWebExtensionInstalledSummary] = []
    @State private var browserExtensionErrorAlertMessage = ""
    @State private var showBrowserExtensionErrorAlert = false

    private var browserExtensionsSubtitle: String {
        guard BrowserWebExtensionSupport.isAvailable else {
            return String(localized: "settings.browser.extensions.subtitleUnsupported", defaultValue: "Browser extensions require macOS 15.4 or later.")
        }
        switch browserExtensionSummaries.count {
        case 0:
            return String(localized: "settings.browser.extensions.subtitleEmpty", defaultValue: "Install Safari Web Extension app bundles. Direct .appex loading requires Developer Mode.")
        case 1:
            return String(localized: "settings.browser.extensions.subtitleOne", defaultValue: "1 extension is installed. The system browser engine enforces extension isolation, host access, and permission prompts.")
        default:
            return String(
                format: String(localized: "settings.browser.extensions.subtitleMany", defaultValue: "%d extensions are installed. The system browser engine enforces extension isolation, host access, and permission prompts."),
                browserExtensionSummaries.count
            )
        }
    }

    var body: some View {
        rows
            .onAppear {
                refreshBrowserExtensionSummaries()
            }
            .onReceive(NotificationCenter.default.publisher(for: BrowserWebExtensionSupport.didChangeNotification)) { _ in
                refreshBrowserExtensionSummaries()
            }
            .alert(
                String(localized: "settings.browser.extensions.error.title", defaultValue: "Browser Extension Error"),
                isPresented: $showBrowserExtensionErrorAlert
            ) {
                Button(String(localized: "common.ok", defaultValue: "OK"), role: .cancel) {}
            } message: {
                Text(browserExtensionErrorAlertMessage)
            }
    }

    @ViewBuilder
    private var rows: some View {
        actionsRow

        SettingsCardDivider()

        developerModeRow

        SettingsCardDivider()

        fileAccessRow

        if !browserExtensionSummaries.isEmpty {
            SettingsCardDivider()
            installedExtensionsList
        }
    }

    private var actionsRow: some View {
        SettingsCardRow(
            configurationReview: .settingsOnly,
            String(localized: "settings.browser.extensions", defaultValue: "Browser Extensions"),
            subtitle: browserExtensionsSubtitle,
            searchAnchorID: SettingsSearchIndex.settingID(for: .browser, idSuffix: "extensions")
        ) {
            HStack(spacing: 8) {
                Button(String(localized: "settings.browser.extensions.install", defaultValue: "Install…")) {
                    chooseBrowserExtensionFiles()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!BrowserWebExtensionSupport.isAvailable)

                Button(String(localized: "settings.browser.extensions.reload", defaultValue: "Reload")) {
                    reloadBrowserExtensions()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!BrowserWebExtensionSupport.isAvailable)
            }
            .accessibilityIdentifier("SettingsBrowserExtensionsActions")
        }
    }

    private var developerModeRow: some View {
        SettingsCardRow(
            configurationReview: .json("browser.extensionsDeveloperMode"),
            String(localized: "settings.browser.extensions.developerMode", defaultValue: "Developer Mode"),
            subtitle: String(localized: "settings.browser.extensions.developerMode.subtitle", defaultValue: "Allow direct local .appex loading for development. Normal installs should use signed Safari extension app bundles.")
        ) {
            Toggle("", isOn: $browserExtensionsDeveloperMode)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBrowserExtensionsDeveloperModeToggle")
        }
    }

    private var fileAccessRow: some View {
        SettingsCardRow(
            configurationReview: .json("browser.extensionsAllowFileURLAccess"),
            String(localized: "settings.browser.extensions.fileAccess", defaultValue: "Local File Access"),
            subtitle: String(localized: "settings.browser.extensions.fileAccess.subtitle", defaultValue: "Allow extension host permissions to include file:// URLs after normal install or runtime consent.")
        ) {
            Toggle("", isOn: $browserExtensionsAllowFileURLAccess)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("SettingsBrowserExtensionsFileAccessToggle")
        }
    }

    private var installedExtensionsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(browserExtensionSummaries) { summary in
                installedExtensionRow(summary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityIdentifier("SettingsBrowserExtensionsList")
    }

    private func installedExtensionRow(_ summary: BrowserWebExtensionInstalledSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { summary.isEnabled },
                set: { setBrowserExtensionEnabled($0, id: summary.id) }
            ))
            .labelsHidden()
            .controlSize(.small)
            .disabled(!BrowserWebExtensionSupport.isAvailable)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(summary.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(summary.isLoaded
                         ? String(localized: "settings.browser.extensions.status.loaded", defaultValue: "Loaded")
                         : String(localized: "settings.browser.extensions.status.notLoaded", defaultValue: "Not loaded"))
                        .font(.caption2)
                        .foregroundStyle(summary.isLoaded ? .green : .secondary)
                }

                Text(summary.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let lastError = summary.lastError, !lastError.isEmpty {
                    Text(
                        String(
                            format: String(localized: "settings.browser.extensions.status.error", defaultValue: "Error: %@"),
                            lastError
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Button(String(localized: "settings.browser.extensions.reloadOne", defaultValue: "Reload")) {
                reloadBrowserExtension(id: summary.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!BrowserWebExtensionSupport.isAvailable)

            Button(String(localized: "settings.browser.extensions.remove", defaultValue: "Remove"), role: .destructive) {
                removeBrowserExtension(id: summary.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!BrowserWebExtensionSupport.isAvailable)
        }
    }

    private func refreshBrowserExtensionSummaries() {
        browserExtensionSummaries = BrowserWebExtensionSupport.installedExtensionSummaries()
    }

    private func chooseBrowserExtensionFiles() {
        guard BrowserWebExtensionSupport.isAvailable else {
            browserExtensionErrorAlertMessage = String(localized: "browser.extensions.error.unsupportedOS", defaultValue: "Browser extensions require macOS 15.4 or later.")
            showBrowserExtensionErrorAlert = true
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = String(localized: "settings.browser.extensions.install.title", defaultValue: "Choose Browser Extensions")
        panel.prompt = String(localized: "settings.browser.extensions.install.prompt", defaultValue: "Install")
        guard panel.runModal() == .OK else { return }

        installBrowserExtensions(from: panel.urls)
    }

    private func installBrowserExtensions(from urls: [URL]) {
        Task { @MainActor in
            var warnings: [String] = []
            var failures: [String] = []
            for url in urls {
                do {
                    let result = try await BrowserWebExtensionSupport.installExtension(from: url)
                    if !result.parseErrors.isEmpty {
                        warnings.append(url.lastPathComponent)
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            refreshBrowserExtensionSummaries()
            if !failures.isEmpty {
                browserExtensionErrorAlertMessage = failures.joined(separator: "\n")
                showBrowserExtensionErrorAlert = true
            } else if !warnings.isEmpty {
                browserExtensionErrorAlertMessage = String(
                    localized: "settings.browser.extensions.install.warningGeneric",
                    defaultValue: "The extension was installed but may not function correctly."
                )
                showBrowserExtensionErrorAlert = true
            }
        }
    }

    private func reloadBrowserExtensions() {
        Task { @MainActor in
            await BrowserWebExtensionSupport.reloadInstalledExtensions()
            refreshBrowserExtensionSummaries()
        }
    }

    private func setBrowserExtensionEnabled(_ isEnabled: Bool, id: UUID) {
        Task { @MainActor in
            do {
                _ = try await BrowserWebExtensionSupport.setExtensionEnabled(isEnabled, id: id)
                refreshBrowserExtensionSummaries()
            } catch {
                browserExtensionErrorAlertMessage = error.localizedDescription
                showBrowserExtensionErrorAlert = true
                refreshBrowserExtensionSummaries()
            }
        }
    }

    private func reloadBrowserExtension(id: UUID) {
        Task { @MainActor in
            do {
                _ = try await BrowserWebExtensionSupport.reloadExtension(id: id)
                refreshBrowserExtensionSummaries()
            } catch {
                browserExtensionErrorAlertMessage = error.localizedDescription
                showBrowserExtensionErrorAlert = true
                refreshBrowserExtensionSummaries()
            }
        }
    }

    private func removeBrowserExtension(id: UUID) {
        Task { @MainActor in
            do {
                try await BrowserWebExtensionSupport.removeExtension(id: id)
                refreshBrowserExtensionSummaries()
            } catch {
                browserExtensionErrorAlertMessage = error.localizedDescription
                showBrowserExtensionErrorAlert = true
                refreshBrowserExtensionSummaries()
            }
        }
    }
}
