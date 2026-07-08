import CmuxDockExtensions
import SwiftUI

/// The consent window content: everything an extension will run — pinned
/// commit, build steps, pane commands, env — shown before anything executes.
/// Also hosts the flow's input/loading/failure/success states.
@MainActor
struct ExtensionConsentView: View {
    let coordinator: ExtensionInstallCoordinator
    @State private var promptInput = ""

    var body: some View {
        Group {
            switch coordinator.phase {
            case .idle, .prompting:
                promptContent
            case .loading(let input):
                statusContent(
                    spinner: true,
                    title: String(
                        localized: "extensions.consent.loading",
                        defaultValue: "Fetching \(input)…"
                    ),
                    detail: String(
                        localized: "extensions.consent.loading.detail",
                        defaultValue: "Resolving the commit and downloading a pinned copy. Nothing runs yet."
                    )
                )
            case .consent(let preview):
                consentContent(preview)
            case .installing(let preview):
                statusContent(
                    spinner: true,
                    title: String(
                        localized: "extensions.consent.installing",
                        defaultValue: "Installing \(preview.manifest.name)…"
                    ),
                    detail: preview.manifest.buildStepsForCurrentPlatform.isEmpty
                        ? nil
                        : String(
                            localized: "extensions.consent.installing.build",
                            defaultValue: "Running build steps. Logs are kept in ~/.local/state/cmux/extensions/logs."
                        )
                )
            case .failed(let message):
                failedContent(message)
            case .installed(let name, let openPaneQualifiedId):
                installedContent(name: name, openPaneQualifiedId: openPaneQualifiedId)
            }
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    // MARK: - Prompt

    private var promptContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                String(localized: "extensions.consent.prompt.title", defaultValue: "Install a Dock extension"),
                systemImage: "puzzlepiece.extension"
            )
            .font(.system(size: 15, weight: .semibold))
            Text(String(
                localized: "extensions.consent.prompt.detail",
                defaultValue: "Enter a public GitHub repository (owner/repo or owner/repo/subdirectory). You will review the exact commands it runs before anything executes."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            TextField(
                String(localized: "extensions.consent.prompt.placeholder", defaultValue: "owner/repo"),
                text: $promptInput
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(submitPrompt)
            Spacer()
            HStack {
                Button(String(localized: "extensions.consent.cancel", defaultValue: "Cancel")) {
                    coordinator.cancel()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "extensions.consent.continue", defaultValue: "Continue")) {
                    submitPrompt()
                }
                .buttonStyle(.borderedProminent)
                .disabled(promptInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func submitPrompt() {
        let input = promptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        promptInput = ""
        coordinator.beginInstall(input: input)
    }

    // MARK: - Consent

    private func consentContent(_ preview: DockExtensionInstallPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(preview)
                .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    trustBox(preview)
                    if !preview.warnings.isEmpty {
                        warningsBox(preview.warnings)
                    }
                    commandsSection(preview)
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button(String(localized: "extensions.consent.cancel", defaultValue: "Cancel")) {
                    coordinator.cancel()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(confirmTitle(preview)) {
                    coordinator.confirm()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("ExtensionConsentInstallButton")
            }
            .padding(16)
        }
    }

    private func confirmTitle(_ preview: DockExtensionInstallPreview) -> String {
        switch preview.kind {
        case .install:
            return String(localized: "extensions.consent.install", defaultValue: "Install")
        case .update:
            return String(localized: "extensions.consent.update", defaultValue: "Update")
        }
    }

    private func header(_ preview: DockExtensionInstallPreview) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: preview.manifest.iconSystemName)
                .font(.system(size: 26))
                .frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(preview.manifest.name) \(preview.manifest.version)")
                    .font(.system(size: 15, weight: .semibold))
                Text(sourceLine(preview))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let description = preview.manifest.description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sourceLine(_ preview: DockExtensionInstallPreview) -> String {
        var line = preview.source.description
        if let sha = preview.resolvedSha {
            line += " @ \(sha.prefix(7))"
        }
        if case .update(let previousSha?) = preview.kind {
            // One localized fragment: translations control the whole
            // parenthetical, including punctuation and word order.
            line += "  " + String(
                localized: "extensions.consent.updateFrom",
                defaultValue: "(currently \(String(previousSha.prefix(7))))"
            )
        }
        return line
    }

    private func trustBox(_ preview: DockExtensionInstallPreview) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    localized: "extensions.consent.trust",
                    defaultValue: "Extensions are not reviewed by cmux. This one will run as you, with your environment, and can use the cmux CLI."
                ))
                Text(String(
                    localized: "extensions.consent.pinNote",
                    defaultValue: "Installing pins it to the commit shown above and enables the Dock beta feature. It never updates without asking again."
                ))
                .foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func warningsBox(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func commandsSection(_ preview: DockExtensionInstallPreview) -> some View {
        let buildSteps = preview.manifest.buildStepsForCurrentPlatform
        if !buildSteps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(String(
                    localized: "extensions.consent.buildSteps",
                    defaultValue: "Runs once at install (build steps)"
                ))
                ForEach(Array(buildSteps.enumerated()), id: \.offset) { _, step in
                    commandLine(step.shellCommand)
                }
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(String(
                localized: "extensions.consent.panes",
                defaultValue: "Runs when you open its Dock panes"
            ))
            ForEach(preview.manifest.panesForCurrentPlatform, id: \.id) { pane in
                VStack(alignment: .leading, spacing: 3) {
                    Text(pane.title)
                        .font(.system(size: 12, weight: .medium))
                    commandLine(pane.shellCommand)
                    if let cwd = pane.cwd {
                        detailLine(String(
                            localized: "extensions.consent.paneCwd",
                            defaultValue: "in \(cwd)/"
                        ))
                    }
                    if !pane.env.isEmpty {
                        // Full assignments, not just names: this dialog is the
                        // trust boundary, and values like PATH/NODE_OPTIONS/
                        // DYLD_* change what actually runs.
                        detailLine(String(
                            localized: "extensions.consent.paneEnv",
                            defaultValue: "env: \(Self.envAssignments(pane.env))"
                        ))
                    }
                }
            }
        }
    }

    /// Sorted `KEY=value` lines with long values truncated for display (the
    /// full values still ship to the pane; truncation only limits the dialog).
    static func envAssignments(_ env: [String: String]) -> String {
        env.keys.sorted().map { key in
            let value = env[key] ?? ""
            let shown = value.count > 200 ? value.prefix(200) + "…" : Substring(value)
            return "\(key)=\(shown)"
        }
        .joined(separator: "\n")
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func commandLine(_ command: String) -> some View {
        Text("$ \(command)")
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func detailLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    // MARK: - Status / terminal states

    private func statusContent(spinner: Bool, title: String, detail: String?) -> some View {
        VStack(spacing: 10) {
            if spinner {
                ProgressView()
                    .controlSize(.small)
            }
            Text(title)
                .font(.system(size: 13, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedContent(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            Text(String(localized: "extensions.consent.failed", defaultValue: "Couldn't install the extension"))
                .font(.system(size: 13, weight: .semibold))
            ScrollView {
                Text(message)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            Button(String(localized: "extensions.consent.close", defaultValue: "Close")) {
                coordinator.dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func installedContent(name: String, openPaneQualifiedId: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.green)
            Text(String(localized: "extensions.consent.installed", defaultValue: "\(name) is installed"))
                .font(.system(size: 13, weight: .semibold))
            Text(String(
                localized: "extensions.consent.installed.detail",
                defaultValue: "Open its panes from the Dock, the command palette, or Settings → Extensions."
            ))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            HStack {
                Button(String(localized: "extensions.consent.close", defaultValue: "Close")) {
                    coordinator.dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if let openPaneQualifiedId {
                    Button(String(localized: "extensions.consent.openNow", defaultValue: "Open Now")) {
                        coordinator.dismiss()
                        DockExtensionsRuntime.shared.openPaneOrBeep(qualifiedId: openPaneQualifiedId)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
