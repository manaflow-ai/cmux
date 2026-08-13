import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite
struct MobileCaffeineStatusTests {
    @Test
    func decodesAuthoritativeEnabledState() throws {
        let enabled = try MobileCaffeineStatus.decode(Data(#"{"enabled":true}"#.utf8))
        let disabled = try MobileCaffeineStatus.decode(Data(#"{"enabled":false}"#.utf8))

        #expect(enabled == MobileCaffeineStatus(enabled: true))
        #expect(disabled == MobileCaffeineStatus(enabled: false))
    }

    @Test
    func rejectsMissingState() {
        #expect(throws: DecodingError.self) {
            try MobileCaffeineStatus.decode(Data("{}".utf8))
        }
    }
}
