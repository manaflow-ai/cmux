import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// An installed app's grant: every requested and optional scope with the
/// app's reason and an Allowed switch (revoke takes effect on the next
/// call, no reinstall), and the "Run sandboxed" switch. The engine reads
/// the result per call (`AppGrants`). The switch shows only for an app that
/// asks for a scope and is not built into cmux: elsewhere it changes nothing.
struct AppGrantsView: View {
    let model: AppStoreModel
    let app: InstalledApp
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            if Self.offersSandbox(app) { sandbox }
            ForEach(app.manifest.scopes) { scope in row(scope, optional: false) }
            ForEach(app.manifest.optionalScopes) { scope in row(scope, optional: true) }
        }
    }

    static func offersSandbox(_ app: InstalledApp) -> Bool {
        !app.isBuiltIn && !(app.manifest.scopes.isEmpty && app.manifest.optionalScopes.isEmpty)
    }

    private var sandbox: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.space3) {
            Icon(.securityLock, size: CGFloat.iconFloor).foregroundStyle(colors.secondary)
            Text(AppsStrings.runSandboxed).font(Font(Typography.bodyEmphasized)).foregroundStyle(colors.primary)
            Spacer()
            toggle(app.isSandboxed, label: AppsStrings.runSandboxed, id: "sandbox") { on in
                // task-owner: one sandbox switch from a toggle
                Task { try? await model.setSandboxed(app.id, on) }
            }
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
