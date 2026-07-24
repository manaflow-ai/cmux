import CmuxSimulator
import Testing

@testable import CmuxSimulatorUI

@Suite("Simulator device quick controls")
struct SimulatorDeviceQuickControlTests {
  @Test("iPhone matches Apple's compact device controls")
  func iPhoneControls() {
    #expect(
      SimulatorDeviceQuickControl.available(for: .iPhone) == [
        .home, .screenshot, .rotate,
      ])
  }

  @Test("iPad adds pointer and keyboard capture")
  func iPadControls() {
    #expect(
      SimulatorDeviceQuickControl.available(for: .iPad) == [
        .home, .screenshot, .rotate, .pointerCapture, .keyboardCapture,
      ])
  }

  @Test("Unsupported device families have no floating controls")
  func unsupportedFamily() {
    #expect(SimulatorDeviceQuickControl.available(for: nil).isEmpty)
  }
}
