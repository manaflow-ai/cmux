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

    /// The old host (`agent.pageHost` off, the default) gets a script; an empty one dropped every card.
    @Test func theOldHostGetsThePortThroughTheStoresWindowHook() {
        let event = AgentPageEvent.cloudPreviewPort(port: 3000, process: "vite", machineID: "vm_a")
        #expect(event.cloudPreviewPortScript.hasPrefix("window.cmuxAcpmuxCloudPreviewPort?.({"))
        #expect(event.cloudPreviewPortScript.contains(#""port":3000"#))
    }
}
