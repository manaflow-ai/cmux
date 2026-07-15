import Combine
import Foundation

/// Native pane for viewing Subrouter accounts and adding the locally signed-in Codex account.
@MainActor
final class SubrouterPanel: Panel, ObservableObject {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .subrouter
    let model: SubrouterPaneModel

    var displayTitle: String {
        String(localized: "subrouterPane.title", defaultValue: "Subrouter")
    }

    var displayIcon: String? { "point.3.connected.trianglepath.dotted" }

    init(service: any SubrouterAccountServicing) {
        model = SubrouterPaneModel(service: service)
    }

    func focus() {}
    func unfocus() {}
    func close() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) { _ = reason }
}
