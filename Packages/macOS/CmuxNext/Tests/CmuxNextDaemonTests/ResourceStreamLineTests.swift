import Foundation
import Testing
@testable import CmuxNextDaemon

/// A routed resource stream (`DaemonConnection.resourceStream`, `tailnet.state`): a `stream_item`
/// hands its item over, `stream_end` and a line that is not a stream line end the reader.
@Suite struct ResourceStreamLineTests {
    @Test func itemEndAndJunk() throws {
        let item = #"{"protocol":"cmux.protocol/2","type":"stream_item","stream_id":"stream_a","sequence":0,"item":{"state":"running"}}"#
        let parsed = try #require(ResourceStreamLine.parse(Data(item.utf8)))
        let object = try JSONSerialization.jsonObject(with: try #require(parsed)) as? [String: String]
        #expect(object == ["state": "running"])

        let end = #"{"type":"stream_end","stream_id":"stream_a","reason":"gap"}"#
        #expect(ResourceStreamLine.parse(Data(end.utf8)) == .some(nil))
        #expect(ResourceStreamLine.parse(Data("not json".utf8)) == nil)
        #expect(ResourceStreamLine.parse(Data(#"{"type":"stream_item","item":3}"#.utf8)) == .some(nil),
                "an item that is not an object ends the stream")
    }
}
