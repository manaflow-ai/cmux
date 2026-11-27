import Foundation
@testable import CmuxNextCloud
import Testing

/// cmux#47638: a Cloud start whose machine's exec route refused it as not running (`vm_not_running`) though its link was
/// up starts or resumes the machine itself (``CloudWait/startStopped(status:within:read:resume:)``), then reads again.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudStartStoppedTests {
    /// A machine record as the app's reads apply it: `next` is what the next read finds, `resumed` what Resume Machine
    /// leaves it at (nil: the resume is refused with `refusal`).
    @MainActor final class Record {
        var status: CloudMachine.Status
        var next: [CloudMachine.Status]
        var resumed: CloudMachine.Status?
        var resumes = 0, reads = 0
        init(_ status: CloudMachine.Status, then next: [CloudMachine.Status] = [], resumed: CloudMachine.Status? = .running) {
            (self.status, self.next, self.resumed) = (status, next, resumed)
        }
        func read() {
            reads += 1
            if !next.isEmpty { status = next.removeFirst() }
        }
        func resume() throws {
            resumes += 1
            guard let resumed else { throw Refusal() }
            status = resumed
        }
    }

    struct Refusal: Error, Equatable {}

    private static func run(_ record: Record) async throws {
        try await CloudWait.startStopped(status: { record.status }, within: .seconds(10), read: { _ in record.read() }) { try record.resume() }
    }

    /// The link's record still read running while the platform's read paused: the read again finds it paused, and it resumes once.
    @Test func aMachineTheReadFindsPausedResumesOnce() async throws {
        let record = Record(.running, then: [.paused])
        try await Self.run(record)
        #expect(record.resumes == 1)
        #expect(record.status == .running)
    }

    /// An idle pause landing as the start came: the pause is waited out, then the machine resumes.
    @Test func aPauseInFlightIsWaitedOutThenResumed() async throws {
        let record = Record(.pausing, then: [.pausing, .pausing, .paused])
        try await Self.run(record)
        #expect(record.resumes == 1)
        #expect(record.status == .running)
    }

    /// A machine already starting (the link's own connect started it) is waited for, never resumed again.
    @Test func aStartInFlightIsWaitedForWithNoResume() async throws {
        let record = Record(.starting, then: [.starting, .starting, .running])
        try await Self.run(record)
        #expect(record.resumes == 0)
        #expect(record.status == .running)
    }

    /// A resume refused because another resume went first (`not_paused`): the record read again starts or runs, and the
    /// start waits for it. A resume refused while the machine stays paused (a quota, a plan) is the start's failure.
    @Test func aResumeRefusedOnlyBecauseItStartedElsewhereIsWaitedOut() async throws {
        let raced = Record(.paused, then: [.paused, .starting, .running], resumed: nil)
        try await Self.run(raced)
        #expect(raced.resumes == 1)
        #expect(raced.status == .running)

        let refused = Record(.paused, then: [.paused, .paused], resumed: nil)
        await #expect(throws: Refusal.self) { try await Self.run(refused) }
        #expect(refused.resumes == 1)
    }
}
