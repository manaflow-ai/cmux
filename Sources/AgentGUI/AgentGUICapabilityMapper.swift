import CmuxAgentWire
import CmuxAgentTruthKit
import Foundation

struct AgentGUICapabilityMapper {
    func map(_ reason: CapabilityReason) -> GuiCapabilityReason {
        switch reason {
        case .cliVersionBelowMinimum(let found, let minimum):
            GuiCapabilityReason(
                code: reason.localizationKey,
                detail: "found=\(found) minimum=\(minimum)"
            )
        default:
            GuiCapabilityReason(code: reason.localizationKey)
        }
    }
}
