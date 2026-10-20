import Foundation
import Testing
@testable import CmuxSimulator

@Suite("Raw HID button protocol")
struct SimulatorHIDButtonProtocolTests {
    @Test("Usage page, usage, and phase survive worker framing")
    func roundTrip() throws {
        let message = SimulatorWorkerInbound.hidButton(SimulatorHIDButtonEvent(
            button: SimulatorHIDButtonUsage(page: 0xFF01, usage: 0x200),
            phase: .down
        ))

        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(SimulatorWorkerInbound.self, from: encoded)

        #expect(decoded == message)
    }
}
