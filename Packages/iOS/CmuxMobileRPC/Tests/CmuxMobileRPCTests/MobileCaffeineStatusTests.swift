import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite
struct MobileCaffeineStatusTests {
    @Test
    func decodesAuthoritativeEnabledState() throws {
        let enabled = try MobileCaffeineStatus(decoding: Data(#"{"enabled":true}"#.utf8))
        let disabled = try MobileCaffeineStatus(decoding: Data(#"{"enabled":false}"#.utf8))

        #expect(enabled == MobileCaffeineStatus(enabled: true))
        #expect(disabled == MobileCaffeineStatus(enabled: false))
    }

    @Test
    func rejectsMissingState() {
        #expect(throws: DecodingError.self) {
            try MobileCaffeineStatus(decoding: Data("{}".utf8))
        }
    }
}
