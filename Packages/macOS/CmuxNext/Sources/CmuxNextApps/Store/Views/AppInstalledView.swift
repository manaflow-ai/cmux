import CmuxNextDesign
import SwiftUI

/// Installed: every installed app with its grants, Run sandboxed, Hide or
/// Show, Enabled, Logs and Remove (a default first-party app shows
/// "Installed for everyone" instead of Remove).
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
            .padding(Metrics.space5)
        }
        .overlay {
            if model.installedApps.isEmpty {
                Text(model.client.isAvailable ? AppsStrings.noneInstalled : AppsStrings.nothingListed)
                    .font(Font(Typography.body)).foregroundStyle(colors.tertiary)
            }
        }
    }
}

/// One installed app. Switches show the visible state; a refused change
/// animates back to the mirror.
struct AppInstalledRow: View {
    let model: AppStoreModel
    let app: AppRecord
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack(spacing: Metrics.space3) {
                AppIconView(icon: app.manifest.icon, bundleDirectory: app.bundleDirectory, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Metrics.space2) {
                        Text(app.manifest.name.resolved()).font(Font(Typography.bodyEmphasized)).foregroundStyle(colors.primary)
                        Text(app.version).font(Font(Typography.caption).monospacedDigit()).foregroundStyle(colors.tertiary)
                        if app.source == .local { AppStoreBadge(text: AppsStrings.localBadge) }
                        if app.hidden { AppStoreBadge(text: AppsStrings.hiddenBadge) }
                    }
                    Text(status.text).font(Font(Typography.caption))
                        .foregroundStyle(status.alert ? colors.attention : colors.secondary).lineLimit(1)
                }
                Spacer()
                Toggle(AppsStrings.enabled, isOn: Binding(get: { app.enabled }, set: { enabled in
                    // task-owner: one enable/disable from a toggle
                    Task { try? await model.setEnabled(app.id, enabled) }
                }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .tint(colors.secondary)
                .disabled(!model.canChange)
                .help(AppsStrings.enabled)
                .accessibilityIdentifier("appStore.enabled.\(app.id)")
                iconButton(app.hidden ? "eye" : "eye.slash", app.hidden ? AppsStrings.show : AppsStrings.hide, id: "hide") {
                    // task-owner: one hide/show from a button
                    Task { try? await model.setHidden(app.id, !app.hidden) }
                }
                .disabled(!model.canChange)
                iconButton("checkmark.shield", AppsStrings.permissions, id: "grants") {
                    model.grantsShown = model.grantsShown == app.id ? nil : app.id
                }
                iconButton("text.alignleft", model.logsShown == app.id ? AppsStrings.hideLogs : AppsStrings.logs, id: "logs") {
                    model.logsShown = model.logsShown == app.id ? nil : app.id
                }
                AppInstallButton(model: model, id: app.id)
            }
            if model.grantsShown == app.id { AppGrantsView(model: model, app: app).padding(.leading, 32 + Metrics.space3) }
            if model.logsShown == app.id { logs }
        }
        .padding(Metrics.space3)
        .background(RoundedRectangle(cornerRadius: Metrics.itemCornerRadius + 2, style: .continuous).fill(colors.hover))
        .animation(Motion.animation(.focus), value: app)
    }

    /// The host state when it stopped on its own, a refusal, else the id.
    private var status: (text: String, alert: Bool) {
        if let rejection = model.client.rejections[app.id] { return (rejection, true) }
        if let host = model.client.hostStates[app.id], host.state == .crashed { return (host.reason ?? AppsStrings.crashed, true) }
        return (app.id, false)
    }

    private var logs: some View {
        let lines = model.client.logs[app.id] ?? []
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

    private func iconButton(_ symbol: String, _ help: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(colors.secondary).frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier("appStore.\(id).\(app.id)")
    }
}
