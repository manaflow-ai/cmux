import Foundation
import Testing
@testable import CmuxMobileRPC

struct MobileTerminalPasteResponseTests {
    @Test("A paste response exposes whether the submit key was accepted")
    func decodesSubmitted() throws {
        let submitted = try MobileTerminalPasteResponse.decode(
            Data(#"{"submitted":true,"workspace_id":"w","surface_id":"s"}"#.utf8)
        )
        #expect(submitted.submitted)

        let notSubmitted = try MobileTerminalPasteResponse.decode(
            Data(#"{"submitted":false,"submit_error":"surface_unavailable"}"#.utf8)
        )
        #expect(!notSubmitted.submitted)
    }
}
