import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = SurfaceStatusManagerModel()
    @State private var confirmsInstall = false
    @State private var confirmsUninstall = false
    @State private var showsRemovalGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            extensionStatus
            adapterStatus
            Divider()
            actions
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 420, alignment: .topLeading)
        .task { model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
        }
        .alert(
            String(localized: "manager.error.title", defaultValue: "Surface Status Couldn’t Complete the Operation"),
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            )
        ) {
            Button(String(localized: "manager.action.ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(model.presentedError ?? "")
        }
        .sheet(isPresented: $showsRemovalGuide) {
            removalGuide
        }
        .confirmationDialog(
            String(localized: "manager.install.title", defaultValue: "Install lifecycle integrations?"),
            isPresented: $confirmsInstall
        ) {
            Button(String(localized: "manager.action.install", defaultValue: "Install Integrations")) {
                model.install()
            }
            Button(String(localized: "manager.action.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(
                localized: "manager.install.message",
                defaultValue: "Pi and OpenCode receive status-only plugins. Codex keeps cmux’s native hooks and adds only a launch-attribution shell helper so its name appears before the first prompt. Open a new shell after changes."
            ))
        }
        .confirmationDialog(
            String(localized: "manager.uninstall.title", defaultValue: "Uninstall lifecycle adapters?"),
            isPresented: $confirmsUninstall
        ) {
            Button(String(localized: "manager.action.uninstall", defaultValue: "Uninstall Integrations"), role: .destructive) {
                model.uninstall()
            }
            Button(String(localized: "manager.action.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(
                localized: "manager.uninstall.message",
                defaultValue: "Only app-owned Pi/OpenCode adapters and the Codex launch-attribution helper are removed. Native Claude and Codex hooks, agent sessions, Herdr hooks, and cmux settings are preserved."
            ))
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "manager.title", defaultValue: "CMUX Surface Status"))
                    .font(.title2.weight(.semibold))
                Text(String(
                    localized: "manager.subtitle",
                    defaultValue: "Manage optional Pi/OpenCode lifecycle adapters and Codex launch attribution for the bundled cmux sidebar extension."
                ))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var extensionStatus: some View {
        HStack {
            Label(
                String(localized: "manager.extension.title", defaultValue: "Sidebar Extension"),
                systemImage: "puzzlepiece.extension"
            )
            Spacer()
            statusBadge(
                String(localized: "manager.extension.bundled", defaultValue: "Bundled"),
                color: .green
            )
        }
    }

    private var adapterStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "manager.adapters.title", defaultValue: "Agent Integrations"))
                .font(.headline)
            ForEach(rows) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusBadge(row.status, color: row.color)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var actions: some View {
        HStack {
            Button(String(localized: "manager.action.useInCmux", defaultValue: "Use in cmux")) {
                useSurfaceStatusInCmux()
            }
            Button(String(localized: "manager.action.refresh", defaultValue: "Refresh")) {
                model.refresh()
            }
            Button(String(localized: "manager.action.removeGuide", defaultValue: "Remove Surface Status…")) {
                showsRemovalGuide = true
            }
            Spacer()
            Button(String(localized: "manager.action.disable", defaultValue: "Disable")) {
                model.disable()
            }
            .disabled(model.isWorking || !canDisable)
            Button(String(localized: "manager.action.enable", defaultValue: "Enable")) {
                model.enable()
            }
            .disabled(model.isWorking || !canEnable)
            Button(String(localized: "manager.action.uninstall", defaultValue: "Uninstall Integrations"), role: .destructive) {
                confirmsUninstall = true
            }
            .disabled(model.isWorking || model.inspection?.receiptPresent != true)
            Button(String(localized: "manager.action.install", defaultValue: "Install Integrations")) {
                confirmsInstall = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking || !canInstall)
        }
        .overlay {
            if model.isWorking { ProgressView().controlSize(.small) }
        }
    }

    private var removalGuide: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "manager.removal.title", defaultValue: "Remove Surface Status"))
                .font(.title2.weight(.semibold))
            Text(String(
                localized: "manager.removal.intro",
                defaultValue: "Removing lifecycle adapters and removing the sidebar extension are separate actions."
            ))
            .foregroundStyle(.secondary)
            removalStep(1, String(localized: "manager.removal.step1", defaultValue: "In cmux, open Sidebar Extensions, select another sidebar, and disable Surface Status."))
            removalStep(2, String(localized: "manager.removal.step2", defaultValue: "Return here and uninstall the receipt-owned Pi/OpenCode adapters and Codex launch helper if desired."))
            removalStep(3, String(localized: "manager.removal.step3", defaultValue: "Quit this app, then move CMUX Surface Status Sidebar.app to the Trash. Removing the containing app removes its embedded extension."))
            removalStep(4, String(localized: "manager.removal.step4", defaultValue: "Reopen cmux’s extension browser if a stale registration remains visible."))
            HStack {
                Button(String(localized: "manager.action.openCmux", defaultValue: "Open cmux")) { openCmux() }
                Button(String(localized: "manager.action.showInFinder", defaultValue: "Show This App in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Spacer()
                Button(String(localized: "manager.action.done", defaultValue: "Done")) {
                    showsRemovalGuide = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 340)
    }

    private func removalStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(.tint.opacity(0.14), in: Circle())
            Text(text)
        }
    }

    private func useSurfaceStatusInCmux() {
        do {
            try SurfaceStatusCmuxSelection.apply()
            openCmux()
        } catch {
            model.presentedError = String(
                localized: "manager.error.cmuxSelectionFailed",
                defaultValue: "Surface Status could not update cmux’s sidebar selection."
            )
        }
    }

    private func openCmux() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SurfaceStatusCmuxSelection.cmuxBundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            model.presentedError = String(localized: "manager.error.cmuxNotFound", defaultValue: "cmux could not be found in Applications.")
        }
    }

    private var canInstall: Bool {
        model.inspection?.adapters.contains { $0.state == .notInstalled || $0.state == .updateAvailable } == true
    }

    private var canDisable: Bool {
        model.inspection?.adapters.contains { $0.state == .enabled } == true
    }

    private var canEnable: Bool {
        model.inspection?.adapters.contains { $0.state == .disabled } == true
    }

    private var rows: [IntegrationRow] {
        let states = Dictionary(uniqueKeysWithValues: (model.inspection?.adapters ?? []).map { ($0.id, $0.state) })
        return [
            managedRow(name: "Pi", id: "pi", state: states["pi"]),
            managedRow(name: "OpenCode", id: "opencode", state: states["opencode"]),
            IntegrationRow(
                id: "claude",
                name: "Claude",
                detail: String(localized: "manager.agent.claude.detail", defaultValue: "Uses cmux’s native lifecycle store; no adapter is installed."),
                status: String(localized: "manager.state.native", defaultValue: "Native"),
                color: .green
            ),
            managedRow(
                name: "Codex",
                id: "codex",
                state: states["codex"],
                detail: String(
                    localized: "manager.agent.codex.detail",
                    defaultValue: "Uses cmux’s native persistent hooks plus a launch-only shell helper. The helper reports no prompts or lifecycle events; open a new shell after changes."
                )
            ),
        ]
    }

    private func managedRow(
        name: String,
        id: String,
        state: SurfaceStatusAdapterState?,
        detail: String? = nil
    ) -> IntegrationRow {
        let detail = detail ?? String(localized: "manager.agent.managed.detail", defaultValue: "Status-only adapter; does not change shell or session restore settings.")
        switch state ?? .notInstalled {
        case .notInstalled:
            return .init(id: id, name: name, detail: detail, status: String(localized: "manager.state.notInstalled", defaultValue: "Not Installed"), color: .secondary)
        case .enabled:
            return .init(id: id, name: name, detail: detail, status: String(localized: "manager.state.enabled", defaultValue: "Enabled"), color: .green)
        case .updateAvailable:
            return .init(id: id, name: name, detail: detail, status: String(localized: "manager.state.updateAvailable", defaultValue: "Update Available"), color: .blue)
        case .disabled:
            return .init(id: id, name: name, detail: detail, status: String(localized: "manager.state.disabled", defaultValue: "Disabled"), color: .orange)
        case .drifted:
            return .init(id: id, name: name, detail: detail, status: String(localized: "manager.state.drifted", defaultValue: "Needs Review"), color: .red)
        case .unmanaged:
            return .init(id: id, name: name, detail: detail, status: String(localized: "manager.state.unmanaged", defaultValue: "Unmanaged File"), color: .orange)
        }
    }

    private func statusBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }
}

enum SurfaceStatusCmuxSelection {
    static let cmuxBundleIdentifier = "com.cmuxterm.app"
    static let extensionBundleIdentifier = "dev.vincent.CMUXSurfaceStatusSidebar.Extension"

    private static let extensionsEnabledKey = "extensions.beta.enabled"
    private static let providerKey = "cmuxExtensionSidebar.providerId"
    private static let selectedBundleKey = "cmuxExtensionSidebar.selectedExtensionBundleId"
    private static let selectedNameKey = "cmuxExtensionSidebar.selectedExtensionName"
    private static let hostedExtensionsProvider = "cmux.sidebar.extensions"
    private static let extensionName = "Surface Status"

    static func apply(defaults: UserDefaults? = UserDefaults(suiteName: cmuxBundleIdentifier)) throws {
        guard let defaults else { throw SurfaceStatusCmuxSelectionError.unavailableDefaults }
        defaults.set(true, forKey: extensionsEnabledKey)
        defaults.set(hostedExtensionsProvider, forKey: providerKey)
        defaults.set(extensionBundleIdentifier, forKey: selectedBundleKey)
        defaults.set(extensionName, forKey: selectedNameKey)
        guard defaults.synchronize() else { throw SurfaceStatusCmuxSelectionError.synchronizeFailed }
    }

    static func isApplied(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: extensionsEnabledKey)
            && defaults.string(forKey: providerKey) == hostedExtensionsProvider
            && defaults.string(forKey: selectedBundleKey) == extensionBundleIdentifier
            && defaults.string(forKey: selectedNameKey) == extensionName
    }
}

private enum SurfaceStatusCmuxSelectionError: Error {
    case unavailableDefaults
    case synchronizeFailed
}

private struct IntegrationRow: Identifiable {
    let id: String
    let name: String
    let detail: String
    let status: String
    let color: Color
}

#Preview {
    ContentView()
}
