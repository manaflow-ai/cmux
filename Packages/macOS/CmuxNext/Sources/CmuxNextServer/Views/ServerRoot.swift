import CmuxNextDesign
import SwiftUI

/// Holds the dismiss callback so the SwiftUI root can call it.
@MainActor
final class DismissBox {
    var action: (() -> Void)?
}

/// Reads the style tunables, the border switch and the resolved colors in a
/// tracked scope, so a Debug Settings or theme change updates live.
struct ServerRoot: View {
    let model: ServerModel
    let surface: ServerSurface
    let appearance: ServerAppearance
    let dismiss: DismissBox

    var body: some View {
        content
            .environment(\.serverColors, appearance.colors)
            .environment(\.serverLineWidth, Borders.current.width(1))
            .focusEffectDisabled()
    }

    @ViewBuilder private var content: some View {
        switch surface {
        case let .panel(style):
            ServerPanelView(model: model, style: style ?? ServerTunables.panelStyle.value)
        case let .pairing(style):
            ServerPairingView(model: model, style: style ?? ServerTunables.pairingStyle.value)
        case let .health(style):
            ServerHealthView(model: model, style: style ?? ServerTunables.healthStyle.value)
        case .approver:
            ServerApproverView(model: model) { dismiss.action?() }
        }
    }
}
