@testable import CmuxNextBrowser
import Foundation
import Testing

/// The DevTools event that starts a media roll call (`CEFMediaBridge.isFrameDetached`): a
/// subframe removed or swapped to another process.
@Suite struct CEFMediaBridgeFrameDetachedTests {
    @Test func aFrameDetachedEventStartsARollCall() {
        #expect(CEFMediaBridge.isFrameDetached(#"{"method":"Page.frameDetached","params":{"frameId":"A1","reason":"remove"}}"#))
    }

    @Test func otherMessagesDoNot() {
        #expect(!CEFMediaBridge.isFrameDetached(#"{"method":"Page.frameAttached","params":{"frameId":"A1"}}"#))
        #expect(!CEFMediaBridge.isFrameDetached(#"{"method":"Runtime.bindingCalled","params":{"name":"cmuxMedia","payload":"Page.frameDetached"}}"#))
        #expect(!CEFMediaBridge.isFrameDetached("not json \"Page.frameDetached\""))
    }
}
