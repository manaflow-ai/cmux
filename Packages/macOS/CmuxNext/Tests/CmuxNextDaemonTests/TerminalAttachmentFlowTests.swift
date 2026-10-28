import Foundation
import Testing
@testable import CmuxNextDaemon
import CmuxNextWakeups

/// The attach decoder reads the key press an `output` event echoes (`flow`), so the
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

    /// A daemon with key stages sends them with the echo; one from before them sends none, and the
    /// echo still decodes with its flow (an older daemon with a newer app).
    @Test func anEchoCarriesTheDaemonsKeyStages() throws {
        let staged = try decode(
            #"{"event":"output","surface":3,"data":"YQ==","flow":9,"key_stages":{"received":10,"written":20,"read":30,"sent":40,"lost":1}}"#)
        #expect(staged.flow == 9)
        #expect(staged.keyStamps == TerminalKeyStamps(received: 10, written: 20, read: 30, sent: 40, lost: 1))
        #expect(staged.event == .output(Data("a".utf8), colors: nil))

        let older = try decode(#"{"event":"output","surface":3,"data":"YQ==","flow":9}"#)
        #expect(older.flow == 9 && older.keyStamps == nil)

        let noLost = try decode(
            #"{"event":"output","surface":3,"data":"YQ==","flow":9,"key_stages":{"received":10,"written":0,"read":30,"sent":40}}"#)
        #expect(noLost.keyStamps == TerminalKeyStamps(received: 10, written: 0, read: 30, sent: 40))
    }

    @Test func otherEventsCarryNoFlow() throws {
        let line = Data(#"{"event":"scroll-changed","surface":3,"offset":4,"at_bottom":false}"#.utf8)
        let decoded = try #require(TerminalAttachment.decodeAttachLine(name: "scroll-changed", line: line, surface: surface,
                                                                       decoder: WireCoding.decoder()))
        #expect(decoded.flow == nil)
    }

    /// The flow rides behind its chunk to the session (`inputEcho`): the queue merges output before it
    /// into that chunk, never output after it, so the session and the lane mark the chunk that echoes.
    @Test func anEchoMarkerStaysBehindItsChunk() async {
        let queue = TerminalEventQueue(recorder: nil)
        queue.push(.output(Data("a".utf8), colors: nil))
        queue.push(.output(Data("b".utf8), colors: nil))
        queue.pushWithoutWaiting(.inputEcho(flow: 7))
        queue.push(.output(Data("c".utf8), colors: nil))
        #expect(await queue.next() == .output(Data("ab".utf8), colors: nil))
        #expect(await queue.next() == .inputEcho(flow: 7))
        #expect(await queue.next() == .output(Data("c".utf8), colors: nil))
    }
}
