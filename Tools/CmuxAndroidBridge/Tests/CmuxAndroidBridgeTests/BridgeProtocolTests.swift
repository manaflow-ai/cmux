@testable import CmuxAndroidBridge
import Testing

@Suite struct BridgeProtocolTests {
    @Test func rawRGBAFramesDefaultToTopDownRows() {
        let event = BridgeEvent(type: "frame")

        #expect(event.bottomUp == false)
    }
}
