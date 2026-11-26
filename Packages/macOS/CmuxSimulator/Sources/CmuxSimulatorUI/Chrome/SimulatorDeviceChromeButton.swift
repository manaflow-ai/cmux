import CmuxSimulator
import Foundation

struct SimulatorDeviceChromeButton: Equatable, Sendable {
    typealias Offset = SimulatorDeviceChromeButtonOffset

    let name: String
    let rect: SimulatorRect
    let imageURL: URL?
    let imageDownURL: URL?
    let onTop: Bool
    let normalOffset: Offset
    let rolloverOffset: Offset
    let usagePage: UInt32?
    let usage: UInt32?

    var hidUsage: SimulatorHIDButtonUsage? {
        guard let usagePage, let usage else { return nil }
        return SimulatorHIDButtonUsage(page: usagePage, usage: usage)
    }

    var rolloverTranslation: SimulatorInputDelta {
        SimulatorInputDelta(
            x: rolloverOffset.x - normalOffset.x,
            y: normalOffset.y - rolloverOffset.y
        )
    }
}
