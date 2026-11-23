import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import Foundation
import os
import Testing

/// #44060, #44185: an Objective-C exception caught outside the Swift job it was thrown in leaves the
/// job's executor record dead, and `sendEvent:` finds it later with nothing to say which exception
/// it was. The app's exception preprocessor keeps the main-thread throws inside Swift jobs, keyed by
/// the job's record, so the report names the throw.
@Suite struct JobThrowRecorderTests {
    /// What the preprocessor sees at a throw in a main-actor job: the job's live record.
    @available(macOS 26, *)
    @MainActor
    @Test func aMainThreadThrowInsideAJobIsKeptAtItsRecord() throws {
        let name = "JobThrowProbe-\(UUID().uuidString)"
        let seen = OSAllocatedUnfairLock<UInt?>(initialState: nil)
        _ = Task.immediate { @MainActor in
            seen.withLock { $0 = SwiftExecutorFrames.activeRecord() }
            UncaughtExceptionRecorder.noteThrow(NSException(name: NSExceptionName(name), reason: "inside a job\nsecond line"))
        }
        let record = try #require(seen.withLock { $0 }, "Task.immediate runs inline with a record set")
        let kept = try #require(UncaughtExceptionRecorder.jobThrows.candidates(at: record).first { $0.name == name })
        #expect(kept.reason == "inside a job")
        #expect(!kept.addresses.isEmpty, "the throw's stack is kept to name where it came from")
    }

    /// A main-thread throw where no job runs cannot leave a record dead, so it is not kept.
    @MainActor
    @Test func aMainThreadThrowOutsideAJobIsNotKept() async {
        let name = "OutsideJobProbe-\(UUID().uuidString)"
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform {
                UncaughtExceptionRecorder.noteThrow(NSException(name: NSExceptionName(name), reason: nil))
                done.resume()
            }
        }
        #expect(!UncaughtExceptionRecorder.jobThrows.names.contains(name))
    }
}
