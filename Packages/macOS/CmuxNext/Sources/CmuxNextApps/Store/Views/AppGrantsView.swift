import CmuxNextDesign
import SwiftUI

/// An installed app's grant: every requested and optional scope with the
/// app's reason and an Allowed switch (revoke takes effect on the next
/// call, no reinstall), and the "Run sandboxed" switch. The engine reads
/// the result per call (`AppGrants`).
struct AppGrantsView: View {
    let model: AppStoreModel
    let app: InstalledApp
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.space3) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 11)).foregroundStyle(colors.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppsStrings.runSandboxed).font(Font(Typography.bodyEmphasized)).foregroundStyle(colors.primary)
                    Text(AppsStrings.sandboxedHelp).font(Font(Typography.caption)).foregroundStyle(colors.secondary)
                }
                Spacer()
                toggle(app.isSandboxed, label: AppsStrings.runSandboxed, id: "sandbox") { on in
                    // task-owner: one sandbox switch from a toggle
                    Task { try? await model.setSandboxed(app.id, on) }
                }
            }
            ForEach(app.manifest.scopes) { scope in row(scope, optional: false) }
            ForEach(app.manifest.optionalScopes) { scope in row(scope, optional: true) }
        }
    }

    private func row(_ scope: AppScopeRequest, optional: Bool) -> some View {
        let blocked = app.isSandboxed && (scope.scope.hasPrefix("net:") || scope.scope.hasPrefix("integration:"))
        return HStack(alignment: .firstTextBaseline, spacing: Metrics.space3) {
            AppScopeRow(scope: scope, optional: optional)
            Spacer()
            toggle(app.isGranted(scope.scope), label: "\(AppsStrings.granted) \(scope.scope)", id: scope.scope) { on in
                // task-owner: one grant change from a toggle
                Task { try? await model.setGranted(app.id, scope: scope.scope, on) }
            }
        }
        .opacity(blocked ? 0.45 : 1)
    }

    private func toggle(_ value: Bool, label: String, id: String, set: @escaping (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: { value }, set: set))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            .tint(colors.secondary)
            .accessibilityIdentifier("appStore.grant.\(app.id).\(id)")
    }
}
