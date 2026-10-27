import Foundation
import Testing
@testable import CmuxNextDaemon

/// The attach decoder reads the key press an `output` event echoes (`flow`, p09-observability-018), so the
/// typing probe's decode mark names that press exactly.
struct TerminalAttachmentFlowTests {
    private let surface = SurfaceID(rawValue: 3)

    private func decode(_ json: String) throws -> DecodedAttachLine {
        try #require(TerminalAttachment.decodeAttachLine(name: "output", line: Data(json.utf8), surface: surface,
                                                         decoder: WireCoding.decoder()))
    }

    @Test func anOutputCarriesTheFlowItEchoes() throws {
        // pid 0x1234 in the high 32 bits, press 7 below: past 2^53, so it must decode exactly.
        let flow: UInt64 = 0x1234 << 32 | 7
        let decoded = try decode(#"{"event":"output","surface":3,"data":"YQ==","flow":\#(flow)}"#)
        #expect(decoded.flow == flow)
        #expect(decoded.event == .output(Data("a".utf8), colors: nil))
    }

    @Test func anOutputWithoutAFlowStillDecodes() throws {
        let decoded = try decode(#"{"event":"output","surface":3,"data":"YQ==","generation":2}"#)
        #expect(decoded.flow == nil)
        #expect(decoded.generation == 2)
        #expect(decoded.event == .output(Data("a".utf8), colors: nil))
    }

    @Test func otherEventsCarryNoFlow() throws {
        let line = Data(#"{"event":"scroll-changed","surface":3,"offset":4,"at_bottom":false}"#.utf8)
        let decoded = try #require(TerminalAttachment.decodeAttachLine(name: "scroll-changed", line: line, surface: surface,
                                                                       decoder: WireCoding.decoder()))
        #expect(decoded.flow == nil)
    }

    /// The flow goes just before its chunk to the session (`inputEcho`, p09-observability-102), so the lane
    /// queues that chunk with the flow: the queue never merges output from before the marker into the chunk
    /// after it, and output after the chunk only extends the chunk that carries the echo.
    @Test func anEchoMarkerGoesJustBeforeItsChunk() async {
        let queue = TerminalEventQueue(recorder: nil)
        queue.push(.output(Data("a".utf8), colors: nil))
        queue.push(.output(Data("b".utf8), colors: nil))
        queue.pushWithoutWaiting(.inputEcho(flow: 7))
        queue.push(.output(Data("c".utf8), colors: nil))
        queue.push(.output(Data("d".utf8), colors: nil))
        #expect(await queue.next() == .output(Data("ab".utf8), colors: nil))
        #expect(await queue.next() == .inputEcho(flow: 7))
        #expect(await queue.next() == .output(Data("cd".utf8), colors: nil))
    }
}
