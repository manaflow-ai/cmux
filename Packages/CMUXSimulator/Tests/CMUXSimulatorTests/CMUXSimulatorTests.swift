import XCTest
@testable import CMUXSimulator

final class CMUXSimulatorTests: XCTestCase {
    func testDeviceShortUDIDUsesFirstEightCharacters() {
        let device = CMUXSimulatorDevice(
            udid: "12345678-90AB-CDEF-1234-567890ABCDEF",
            name: "iPhone",
            state: .booted,
            runtime: "iOS 26.4"
        )

        XCTAssertEqual(device.shortUDID, "12345678")
        XCTAssertTrue(device.isBooted)
    }

    func testCapabilityReportSummarizesFirstFailure() {
        let report = CMUXSimulatorCapabilityReport(
            xcodeMajorVersion: 25,
            minimumXcodeMajorVersion: 26,
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            failures: ["Xcode 26+ is required.", "SimulatorKit is unavailable."]
        )

        XCTAssertFalse(report.isUsable)
        XCTAssertEqual(report.failureSummary, "Xcode 26+ is required.")
    }
}
