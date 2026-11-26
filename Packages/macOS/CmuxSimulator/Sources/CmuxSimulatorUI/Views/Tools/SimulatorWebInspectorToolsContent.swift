import CmuxSimulator
import SwiftUI

struct SimulatorWebInspectorToolsContent: View {
    let isAvailable: Bool
    let targets: [SimulatorWebInspectorTarget]
    let session: SimulatorWebInspectorSessionStatus
    let isHighlighted: Bool
    let responses: [SimulatorWebInspectorResponse]
    let refresh: () -> Void
    let attach: (String) -> Void
    let release: () -> Void
    let setHighlight: (Bool) -> Void
    let send: (String) -> Void
    let clearResponses: () -> Void

    var body: some View {
        SimulatorToolSection(simulatorStrings.webInspector) {
            SimulatorWebInspectorTargetPicker(
                isAvailable: isAvailable,
                targets: targets,
                session: session,
                refresh: refresh,
                attach: attach,
                release: release
            )
            SimulatorWebInspectorCommandEditor(
                isAttached: attachedTargetID != nil,
                isHighlighted: isHighlighted,
                setHighlight: setHighlight,
                send: send
            )
            SimulatorWebInspectorResponses(
                responses: responses,
                clear: clearResponses
            )
        }
    }

    private var attachedTargetID: String? {
        guard case let .attached(_, targetID) = session else { return nil }
        return targetID
    }
}
