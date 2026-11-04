@testable import CmuxNextCloud
import Foundation
import Testing

/// The ended app link's list read (``CloudLinkEndRead``) and a list read's record over the
/// session's copy (``CloudMachine/listed(over:connectedSinceRead:)``), moved out of the App's
/// `CloudMachineSession`; `CloudLinkEndedHeaderTests` (CmuxNextAppTests) covers them through it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudLinkEndReadTests {
    /// A dropped link on a machine that does not read paused reads the list forced, once, and
    /// confirms until that read answers with no connect since.
    @Test func aDropOnAMachineNotReadPausedReadsTheListForcedOnceAndConfirmsUntilItAnswers() async {
        let endRead = CloudLinkEndRead()
        let (reads, read) = AsyncStream.makeStream(of: Bool.self)
        let (answers, answer) = AsyncStream.makeStream(of: Void.self)
        endRead.ended(dropped: true, paused: false, connects: 3, connectsNow: { 3 }, read: { force in
            read.yield(force)
            for await _ in answers { break }
        })
        var iterator = reads.makeAsyncIterator()
        #expect(await iterator.next() == true, "one forced list read")
        #expect(endRead.confirming)
        endRead.ended(dropped: true, paused: false, connects: 3, connectsNow: { 3 }, read: { force in read.yield(force) })
        #expect(await iterator.next() == false, "a second end while one confirms reads throttled")
        answer.yield()
        for _ in 0..<1_000 where endRead.confirming { await Task.yield() }
        #expect(!endRead.confirming, "the read answered with no connect since")
    }

    /// A link that was refused, or ended on a machine that reads paused, reads the list throttled
    /// and never confirms.
    @Test func aRefusedLinkOrAPausedMachineReadsTheListThrottled() async {
        let endRead = CloudLinkEndRead()
        let (reads, read) = AsyncStream.makeStream(of: Bool.self)
        endRead.ended(dropped: false, paused: false, connects: 0, connectsNow: { 0 }, read: { force in read.yield(force) })
        endRead.ended(dropped: true, paused: true, connects: 0, connectsNow: { 0 }, read: { force in read.yield(force) })
        var iterator = reads.makeAsyncIterator()
        #expect(await iterator.next() == false)
        #expect(await iterator.next() == false)
        #expect(!endRead.confirming)
    }

    /// A connect since the end is the link's answer: the read's answer leaves ``confirming`` to it.
    @Test func aConnectSinceTheEndKeepsTheReadFromClearingIt() async {
        let endRead = CloudLinkEndRead()
        let (done, finish) = AsyncStream.makeStream(of: Void.self)
        endRead.ended(dropped: true, paused: false, connects: 1, connectsNow: { 2 }, read: { _ in finish.yield() })
        var iterator = done.makeAsyncIterator()
        _ = await iterator.next()
        for _ in 0..<100 { await Task.yield() }
        #expect(endRead.confirming, "only this ended link's read clears it")
    }

    /// A record that is not live, read before a connect began, keeps the live status, pause reason
    /// and running start of the session's copy and takes its other fields.
    @Test func aListedRecordOlderThanAConnectKeepsTheLiveStatus() {
        let since = Date(timeIntervalSince1970: 1_000)
        var current = CloudMachine(id: "vm-1", status: .running, displayName: "Old")
        current.runningSince = since
        var record = CloudMachine(id: "vm-1", status: .paused, displayName: "New")
        record.pauseReason = .idle
        let kept = record.listed(over: current, connectedSinceRead: true)
        #expect(kept.status == .running)
        #expect(kept.pauseReason == nil)
        #expect(kept.runningSince == since)
        #expect(kept.displayName == "New")
        #expect(record.listed(over: current, connectedSinceRead: false) == record, "no connect since the read")
        let live = CloudMachine(id: "vm-1", status: .starting)
        #expect(live.listed(over: current, connectedSinceRead: true) == live, "a live record is taken as it is")
    }
}
