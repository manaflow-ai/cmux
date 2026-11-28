import Foundation
import Testing
@testable import CmuxNextBrowser

/// Data from the network must never trap the app.
@Suite struct HostileInputTests {
    /// A server certificate whose [0] version is INTEGER 0x7FFFFFFFFFFFFFFF
    /// (Page Info reads it as `version + 1`).
    @Test func certificateWithAHugeVersionIsRefusedNotATrap() {
        let der: [UInt8] = [
            0x30, 0x12,
            0x30, 0x0C, 0xA0, 0x0A, 0x02, 0x08, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0x30, 0x00,
            0x03, 0x00,
        ]
        #expect(throws: (any Error).self) { try PageInfoCertificate(der: Data(der)) }
    }
}
