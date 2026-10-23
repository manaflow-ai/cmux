import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AgentPaneUploadTests {
    @Test func acceptsMoreThanTenFilesWithinByteAndNameLimits() {
        let files: [[String: Any]] = (0..<11).map { index in
            ["name": "part-\(index).zip", "data": Data([UInt8(index)]).base64EncodedString()]
        }
        let parsed = AgentPaneUpload.files(["files": files])
        #expect(parsed?.count == 11)
    }
}
