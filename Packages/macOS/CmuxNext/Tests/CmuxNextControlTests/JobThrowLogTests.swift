import CmuxNextControl
import Foundation
import Testing

/// #44060, #44185: the throws kept at a Swift executor record name the one that left it dead.
@Suite struct JobThrowLogTests {
    @Test func theThrowsAtTheDeadRecordAreNamedNewestFirst() {
        var log = JobThrowLog()
        log.note(jobThrow(record: 0x4406, name: "First"))
        log.note(jobThrow(record: 0x4407, name: "Elsewhere"))
        log.note(jobThrow(record: 0x4406, name: "Second"))
        #expect(log.candidates(at: 0x4406).map(\.name) == ["Second", "First"])
    }

    @Test func onlyTheNewestThrowsAreKept() {
        var log = JobThrowLog()
        for index in 0..<(JobThrowLog.limit + 3) { log.note(jobThrow(record: 0x4418, name: "T\(index)")) }
        #expect(log.names.count == JobThrowLog.limit)
        #expect(log.candidates(at: 0x4418).first?.name == "T\(JobThrowLog.limit + 2)")
    }

    /// A throw where no job runs (a fresh thread) cannot leave a record dead, so it is not captured.
    @Test func aThrowOffTheMainThreadIsNotCaptured() async {
        let captured = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            Thread { done.resume(returning: JobThrow.capture(NSException(name: .genericException, reason: nil)) != nil) }.start()
        }
        #expect(!captured)
    }
}

private func jobThrow(record: UInt, name: String) -> JobThrow {
    JobThrow(record: record, name: name, reason: "reason", addresses: [], uptime: 0)
}
