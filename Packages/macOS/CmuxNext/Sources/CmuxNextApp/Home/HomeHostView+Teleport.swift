import AppKit
import CmuxNextCompat
import CmuxNextHomeEngine

/// Chief teleport in a Home conversation: the location chip beside the Chief's name in the header
/// and the Runs On row in the Chief card, both opening the Teleport menu of the app's one
/// ``ChiefTeleportModel`` (its picks run `chief.moveTo` and `chief.moveRollback`).
extension HomeHostView {
    /// Shows the chip and the row while this conversation is the Chief `cmux chief move` moves
    /// (``HomeService/showsTeleport(conversation:)``), and takes them away otherwise.
    func installTeleport(services: AppServices, conversation: String) {
        let model = services.chiefTeleport
        let header = ChiefTeleportChip(model: model)
        header.setAccessibilityIdentifier("cmux.home.chief.teleport.header")
        let card = ChiefTeleportChip(model: model)
        card.setAccessibilityIdentifier("cmux.home.chief.teleport.card")
        let service = services.home
        // task-owner: lives as long as this view (it ends at the first change after the view is released); event-driven (Observation)
        teleportShown = Task { [weak self, weak service] in
            for await shown in ObservationStream({ service?.showsTeleport(conversation: conversation) ?? false }) {
                guard let self else { return }
                transcript.headerPillAccessory = shown ? header : nil
                settingsView.showTeleport(shown ? card : nil)
            }
        }
    }
}
