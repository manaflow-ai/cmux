import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// Installed: every installed app with Enabled, Reload, Logs and Remove.
struct AppInstalledView: View {
    let model: AppStoreModel
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.space2) {
                ForEach(model.installedApps) { app in
                    AppInstalledRow(model: model, app: app)
                }
            }
            .appStoreColumn()
            .padding(.vertical, Metrics.space5)
        }
        .overlay {
            if model.installedApps.isEmpty {
                Text(AppsStrings.noneInstalled).font(Font(Typography.body)).foregroundStyle(colors.tertiary)
            }
        }
    }
}

/// One installed app.
struct AppInstalledRow: View {
    let model: AppStoreModel
    let app: InstalledApp
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack(spacing: Metrics.space3) {
                AppIconView(icon: app.manifest.icon, bundleDirectory: app.bundle.directory, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Metrics.space2) {
                        Text(app.manifest.name.resolved()).font(Font(Typography.bodyEmphasized)).foregroundStyle(colors.primary)
                        Text(app.manifest.version).font(Font(Typography.caption).monospacedDigit()).foregroundStyle(colors.tertiary)
                        if app.bundle.source == .local { AppStoreBadge(text: AppsStrings.localBadge) }
                    }
                    Text(model.host.failures[app.id] ?? app.id).font(Font(Typography.caption))
                        .foregroundStyle(model.host.failures[app.id] == nil ? colors.secondary : colors.attention).lineLimit(1)
                }
                Spacer()
                Toggle(AppsStrings.enabled, isOn: Binding(get: { app.isEnabled }, set: { enabled in
                    // task-owner: one enable/disable from a toggle
                    Task { try? await model.setEnabled(app.id, enabled) }
                }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .tint(colors.secondary)
                .help(AppsStrings.enabled)
                iconButton(.actionReload, AppsStrings.reload) {
                    // task-owner: one reload from a button
                    Task { await model.reload(app.id) }
                }
                // Disabled, not hidden, with nothing to grant: the row's buttons stay in place.
                iconButton(.appPermissions, AppsStrings.permissions, enabled: hasGrants) {
                    model.grantsShown = model.grantsShown == app.id ? nil : app.id
                }
                iconButton(.textDescription, model.logsShown == app.id ? AppsStrings.hideLogs : AppsStrings.logs) {
                    model.logsShown = model.logsShown == app.id ? nil : app.id
                }
                AppInstallButton(model: model, id: app.id, builtIn: app.isBuiltIn)
            }
            if model.grantsShown == app.id, hasGrants { AppGrantsView(model: model, app: app).padding(.leading, 32 + Metrics.space3) }
            if model.logsShown == app.id { logs }
        }
        .padding(Metrics.space3)
        .background(RoundedRectangle(cornerRadius: Metrics.itemCornerRadius + 2, style: .continuous).fill(colors.hover))
    }

    private var hasGrants: Bool { !app.manifest.scopes.isEmpty || !app.manifest.optionalScopes.isEmpty }

    private var logs: some View {
        let lines = model.host.logs[app.id] ?? []
        return VStack(alignment: .leading, spacing: 1) {
            if lines.isEmpty { Text(AppsStrings.noLogs).foregroundStyle(colors.tertiary) }
            ForEach(lines.suffix(200)) { line in
                Text("\(line.level)  \(line.message)")
                    .foregroundStyle(line.level == "error" ? colors.attention : colors.secondary)
                    .textSelection(.enabled)
            }
        }
        .font(Font(Typography.shortcut))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.space2)
        .background(RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous).fill(colors.background))
    }

    private func iconButton(_ icon: IconName, _ help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(icon, size: 14).foregroundStyle(enabled ? colors.secondary : colors.tertiary).frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}
