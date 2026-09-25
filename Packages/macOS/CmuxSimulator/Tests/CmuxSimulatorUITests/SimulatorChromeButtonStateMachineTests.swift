import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("DeviceKit chrome button input")
struct SimulatorChromeButtonStateMachineTests {
    @Test("Raw DeviceKit buttons stay held independently until release or cleanup")
    func simultaneousHoldsAndCleanup() throws {
        let volume = button(name: "volume-up", page: 0x0C, usage: 0xE9)
        let action = button(name: "action", page: 0x0B, usage: 0x2D)
        let volumeDown = try event(volume, phase: .down)
        let volumeUp = try event(volume, phase: .up)
        let actionDown = try event(action, phase: .down)
        let actionUp = try event(action, phase: .up)
        var input = SimulatorChromeButtonStateMachine()

        #expect(input.press(volume) == [.hidButton(volumeDown)])
        #expect(input.press(action) == [.hidButton(actionDown)])
        #expect(input.press(volume).isEmpty)
        #expect(input.heldButtons == Set([volume.hidUsage, action.hidUsage].compactMap { $0 }))
        #expect(input.release(volume) == [.hidButton(volumeUp)])
        #expect(input.releaseAll() == [.hidButton(actionUp)])
        #expect(input.heldButtons.isEmpty)
    }

    @Test("Decorative DeviceKit inputs do not intercept pointer input")
    func decorativeInput() {
        let decorative = button(name: "decoration", page: nil, usage: nil)
        var input = SimulatorChromeButtonStateMachine()

        #expect(input.press(decorative).isEmpty)
        #expect(input.release(decorative).isEmpty)
    }

    private func button(
        name: String,
        page: UInt32?,
        usage: UInt32?
    ) -> SimulatorDeviceChromeProfile.Button {
        SimulatorDeviceChromeProfile.Button(
            name: name,
            rect: SimulatorRect(x: 0, y: 0, width: 20, height: 40),
            imageURL: nil,
            imageDownURL: nil,
            onTop: false,
            normalOffset: .init(x: 0, y: 0),
            rolloverOffset: .init(x: 0, y: 0),
            usagePage: page,
            usage: usage
        )
    }

    private func event(
        _ button: SimulatorDeviceChromeProfile.Button,
        phase: SimulatorKeyPhase
    ) throws -> SimulatorHIDButtonEvent {
        SimulatorHIDButtonEvent(button: try #require(button.hidUsage), phase: phase)
    }
}
