import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct MobileMacPowerStatusTests {
    @Test func decodesAuthoritativeStatus() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "result": [
                "keep_awake_enabled": true,
                "low_power_enabled": false,
            ],
        ])
        let status = try MobileMacPowerStatus.decode(data)
        #expect(status.keepAwakeEnabled)
        #expect(!status.lowPowerEnabled)
    }

    @Test func rejectsIncompleteStatus() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "result": ["keep_awake_enabled": true],
        ])
        #expect(throws: MobileMacPowerError.invalidResponse) {
            try MobileMacPowerStatus.decode(data)
        }
    }
}
