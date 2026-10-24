@testable import CmuxNextAgentPane
import CmuxNextWakeups
import Dispatch
import Foundation
import Testing

/// What `composer.capture` answers the page for what `screencapture` wrote: a capture named for
/// when it was taken (so two in one prompt differ), nothing for a cancelled pick, and a capture too
/// large to attach by name, for the composer's note.
struct AgentPaneCaptureTests {
    private static let taken = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                              year: 2026, month: 10, day: 11, hour: 14, minute: 32, second: 5).date!

    @Test func aCaptureIsNamedForWhenItWasTaken() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let answer = AgentPaneCapture.answer(png, taken: Self.taken)
        #expect(answer["name"] as? String == "Screenshot 2026-10-11 14.32.05.png")
        #expect(answer["mimeType"] as? String == "image/png")
        #expect(answer["data"] as? String == png.base64EncodedString())
    }

    @Test func aCancelledPickAnswersNothingToAttach() {
        let answer = AgentPaneCapture.answer(Data(), taken: Self.taken)
        #expect(answer["cancelled"] as? Bool == true)
        #expect(answer["data"] == nil)
    }

    @Test func aCaptureTooLargeToAttachIsNamedForTheNote() {
        // Bytes over the cap that are no image: nothing can scale them under it.
        let answer = AgentPaneCapture.answer(Data(count: AgentPaneCapture.maxBytes + 1), taken: Self.taken)
        #expect(answer["tooLarge"] as? Bool == true)
        #expect(answer["name"] as? String == "Screenshot 2026-10-11 14.32.05.png")
        #expect(answer["data"] == nil)
    }

    @Test(.timeLimit(.minutes(1))) func theCaptureIsReadAndRemovedOnTheFilesLaneAtUserBlocking() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture-test-\(UUID().uuidString).png")
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        try png.write(to: file)
        let (queuedAt, report) = AsyncStream.makeStream(of: (BlockingLane, WorkPriority).self)
        let work = BackgroundWork(label: "test.capture", onQueued: { report.yield(($0, $1)) })
        // The files lane's userBlocking slot is held: the capture's read can only queue there, not run anywhere else.
        let release = DispatchSemaphore(value: 0)
        let (held, holding) = AsyncStream.makeStream(of: Void.self)
        work.post(.userBlocking, mayBlock: .files) {
            holding.yield()
            release.wait()
        }
        var heldIterator = held.makeAsyncIterator()
        _ = await heldIterator.next()
        let answer = Task { await AgentPaneCapture.collect(file, taken: Self.taken, work: work) }
        var queued = queuedAt.makeAsyncIterator()
        let seen = await queued.next()
        #expect(seen?.0 == .files && seen?.1 == .userBlocking)
        #expect(FileManager.default.fileExists(atPath: file.path), "nothing read it before its slot was free")
        release.signal()
        let value = await answer.value
        #expect(value["data"] as? String == png.base64EncodedString())
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
