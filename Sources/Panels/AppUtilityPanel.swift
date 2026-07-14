import Foundation
import Observation

@MainActor
@Observable
final class AppUtilityPanel: Panel {
    let id = UUID()
    let workspaceId: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .appUtility
    let kind: AppUtilityPanelKind
    let settingsNavigationScope = UUID().uuidString

    private(set) var settingsNavigationTarget: SettingsNavigationTarget?
    private(set) var settingsNavigationRevision = 0

    var displayTitle: String { kind.displayTitle }
    var displayIcon: String? { kind.displayIcon }

    init(
        workspaceId: UUID,
        kind: AppUtilityPanelKind,
        settingsNavigationTarget: SettingsNavigationTarget? = nil
    ) {
        self.workspaceId = workspaceId
        self.kind = kind
        self.settingsNavigationTarget = settingsNavigationTarget
    }

    func requestSettingsNavigation(_ target: SettingsNavigationTarget?) {
        guard kind == .settings, let target else { return }
        settingsNavigationTarget = target
        settingsNavigationRevision &+= 1
    }

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) { _ = reason }
}
