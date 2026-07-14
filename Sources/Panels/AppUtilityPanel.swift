import Combine
import Foundation

@MainActor
final class AppUtilityPanel: Panel {
    enum Kind: String, Equatable, Sendable {
        case settings
        case mobilePairing

        var displayTitle: String {
            switch self {
            case .settings:
                return String(localized: "settings.title", defaultValue: "Settings")
            case .mobilePairing:
                return String(localized: "mobile.pairing.window.title", defaultValue: "Pair iPhone")
            }
        }

        var displayIcon: String {
            switch self {
            case .settings: return "gearshape"
            case .mobilePairing: return "iphone"
            }
        }
    }

    let id = UUID()
    let workspaceId: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .appUtility
    let kind: Kind
    let settingsNavigationScope = UUID().uuidString

    @Published private(set) var settingsNavigationTarget: SettingsNavigationTarget?
    @Published private(set) var settingsNavigationRevision = 0

    var displayTitle: String { kind.displayTitle }
    var displayIcon: String? { kind.displayIcon }

    init(
        workspaceId: UUID,
        kind: Kind,
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
