import Foundation

extension AgentPaneView {
    func applyFleetSagas() {
        deliver([.fleetSagas(fleetSagas)], scripts: ["window.cmuxAcpmuxBridge?.applyFleetSagas?.(\(fleetSagas));"])
    }
}
