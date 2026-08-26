import Testing
@testable import CmuxPeerTransportBridge
import Foundation

@Suite struct PtxLaneDescriptorTests {
    @Test func roundTrip() throws {
        let descriptor = PtxLaneDescriptor(lane: .terminal, resourceID: "surface-1", cursor: 42)
        let decoded = try PtxLaneDescriptor(encoded: descriptor.encoded())
        #expect(decoded == descriptor)
    }
}
