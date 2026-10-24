import Foundation
import Testing
@testable import CmuxNextDaemon

/// On a shared connection the reader thread serves every view: a view queue
/// that falls behind drops its own output instead of blocking the reader (D5).
@Suite struct TerminalEventQueueOverflowTests {
    @Test func aQueueThatMustNotBlockDropsItsOutputButKeepsItsEvents() async {
        let queue = TerminalEventQueue(highWater: 8, lowWater: 2, mergeLimit: 64, blocksReader: false)
        queue.arm()
        #expect(queue.push(.output(Data("12345".utf8), colors: nil)) == .queued)
        #expect(queue.push(.scrollChanged(offset: 3, atBottom: true)) == .queued)
        // Past the high water mark: returns at once (never waits) and drops output.
        #expect(queue.push(.output(Data("67890".utf8), colors: nil)) == .overflowed)
        #expect(queue.bufferedOutputBytes == 0)
        #expect(queue.push(.output(Data("ok".utf8), colors: nil)) == .queued)
        queue.finish()
        var events: [TerminalChannelEvent] = []
        while let event = await queue.next() { events.append(event) }
        #expect(events == [.scrollChanged(offset: 3, atBottom: true), .output(Data("ok".utf8), colors: nil)])
    }
}
