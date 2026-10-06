import SwiftUI

/// The channels that still run a hidden app, as small labels.
struct AccessSummary: View {
    var access: AppHiddenAccess
    @Environment(\.permissionColors) private var colors

    var body: some View {
        let on = [(AppInstallStrings.cli, access.cli), (AppInstallStrings.mcp, access.mcp),
                  (AppInstallStrings.automations, access.automations)].filter(\.1).map(\.0)
        if on.isEmpty {
            Text(AppInstallStrings.runsNowhere).font(colors.caption).foregroundStyle(colors.tertiary)
        } else {
            HStack(spacing: 4) {
                ForEach(on, id: \.self) { label in
                    Text(label).font(colors.caption).foregroundStyle(colors.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(colors.field))
                }
            }
        }
    }
}

/// "While Hidden" in the permissions pane: CLI, MCP and automations
/// toggles (`app.set_hidden_access`, user origin only).
struct HiddenAccessSection: View {
    var appID: String
    var installs: AppInstallsModel
    @Environment(\.permissionColors) private var colors

    var body: some View {
        let state = installs.states[appID] ?? .notInstalled(appID)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading(text: AppInstallStrings.whileHidden)
                if state.hidden {
                    Text(AppInstallStrings.hiddenChip).font(colors.caption).foregroundStyle(colors.secondary)
                }
                Spacer()
                Button(state.hidden ? AppInstallStrings.unhide : AppInstallStrings.hide) {
                    Task { await installs.send(state.hidden ? .unhide : .hide, app: appID) }
                }
                .buttonStyle(PermissionButtonStyle(kind: .quiet))
                .font(colors.caption)
            }
            Text(AppInstallStrings.whileHiddenDetail).font(colors.caption).foregroundStyle(colors.tertiary)
            HStack(spacing: 16) {
                toggle(AppInstallStrings.cli, on: state.hiddenAccess.cli) { .setHiddenAccess(cli: $0, mcp: nil, automations: nil) }
                toggle(AppInstallStrings.mcp, on: state.hiddenAccess.mcp) { .setHiddenAccess(cli: nil, mcp: $0, automations: nil) }
                toggle(AppInstallStrings.automations, on: state.hiddenAccess.automations) {
                    .setHiddenAccess(cli: nil, mcp: nil, automations: $0)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
            .disabled(!state.installed)
        }
    }

    private func toggle(_ label: String, on: Bool, _ op: @escaping (Bool) -> AppStateOp.Kind) -> some View {
        HStack(spacing: 6) {
            PlainSwitch(isOn: on, tone: nil) { Task { await installs.send(op(!on), app: appID) } }
            Text(label).font(colors.body).foregroundStyle(colors.text)
        }
    }
}
