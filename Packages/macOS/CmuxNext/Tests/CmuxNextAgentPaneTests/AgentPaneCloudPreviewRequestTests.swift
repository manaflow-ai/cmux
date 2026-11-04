import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct AgentPaneCloudPreviewRequestTests {
    @Test func onlyAPortIsAcceptedTheMachineAndURLStayHostOwned() {
        #expect(AgentPaneRequest(body: ["method": "cloud.preview.open", "params": ["port": 3000]]) == .openCloudPreview(port: 3000))
        for params: [String: Any] in [
            ["port": 0], ["port": 65536], ["port": true], ["port": 3000.5],
            ["port": "3000"], ["port": 3000, "machine": "other-machine"],
            ["port": 3000, "url": "https://example.com"],
        ] {
            #expect(AgentPaneRequest(body: ["method": "cloud.preview.open", "params": params]) == .unsupported("cloud.preview.open"))
        }
    }
}
