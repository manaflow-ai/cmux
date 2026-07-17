import Foundation
import Testing
@testable import CmuxTerminalRenderer

@Suite
struct RendererProcessOutputRelayTests {
    @Test
    func boundsStartupOutputAndCountsDiscardedPrefix() {
        let relay = RendererProcessOutputRelay(pendingByteLimit: 4)
        let bytes = Array("abcdef".utf8)
        bytes.withUnsafeBufferPointer(relay.append)

        #expect(relay.discardedPrefixByteCount == 2)
    }

    @Test
    func emptyOutputDoesNotChangeBufferAccounting() {
        let relay = RendererProcessOutputRelay(pendingByteLimit: 4)
        let bytes: [UInt8] = []
        bytes.withUnsafeBufferPointer(relay.append)

        #expect(relay.discardedPrefixByteCount == 0)
    }
}
