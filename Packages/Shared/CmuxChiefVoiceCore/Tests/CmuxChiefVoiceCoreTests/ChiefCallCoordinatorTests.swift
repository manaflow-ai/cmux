import CmuxChiefVoiceCore
import Foundation
import Testing

@MainActor
@Suite("ChiefCallCoordinator")
struct ChiefCallCoordinatorTests {
    let recorder = FakeRecorder()
    let transcriber = FakeTranscriber()
    let delivery = FakeDelivery()
    let outbox = VoiceNoteOutbox(directory: temporaryDirectory())
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func coordinator(micGranted: Bool = true) -> ChiefCallCoordinator {
        let start = self.start
        return ChiefCallCoordinator(recorder: recorder, transcriber: transcriber,
                                    microphone: FakeMicrophone(granted: micGranted), delivery: delivery,
                                    outbox: outbox, now: { start })
    }

    @Test func callStartsRecordingIntoTheOutbox() async throws {
        let call = coordinator()
        await call.handle(.call)
        #expect(call.state == .recording(mode: .call, startedAt: start))
        let url = try #require(await recorder.startedURLs.first)
        #expect(url.deletingLastPathComponent().standardizedFileURL == outbox.directory.standardizedFileURL)
        #expect(url.pathExtension == "m4a")
    }

    @Test func deniedMicrophoneNeverRecords() async {
        let call = coordinator(micGranted: false)
        await call.handle(.call)
        #expect(call.state == .permissionDenied)
        #expect(await recorder.startedURLs.isEmpty)
    }

    @Test func endTranscribesDeliversAndEmptiesTheOutbox() async throws {
        let call = coordinator()
        await call.handle(.voiceNote)
        await call.end()
        let delivered = await delivery.delivered
        #expect(delivered.count == 1)
        let first = try #require(delivered.first)
        #expect(first.note.transcript == "Hello Chief, ship the build.")
        #expect(first.note.mode == .voiceNote)
        #expect(first.note.duration == 3.5)
        #expect(first.audioExisted)
        #expect(call.state == .sent(first.note.id))
        #expect(await outbox.pending().isEmpty)
        #expect(await recorder.stops == 1)
    }

    @Test func unreachableChiefKeepsTheNoteAndDrainSendsItLater() async throws {
        await delivery.setReachable(false)
        let call = coordinator()
        await call.handle(.call)
        await call.end()
        let saved = try #require(await outbox.pending().first)
        #expect(call.state == .savedForLater(saved.id))
        #expect(saved.transcript == "Hello Chief, ship the build.")
        #expect(FileManager().fileExists(atPath: outbox.audioURL(for: saved.id).path))

        await delivery.setReachable(true)
        await call.drainOutbox()
        #expect(await delivery.delivered.map(\.note.id) == [saved.id])
        #expect(await outbox.pending().isEmpty)
    }

    @Test func failedTranscriptionStillDeliversTheAudio() async throws {
        await transcriber.set(.failure(FakeError()))
        let call = coordinator()
        await call.handle(.call)
        await call.end()
        let first = try #require(await delivery.delivered.first)
        #expect(first.note.transcript == nil)
        #expect(first.audioExisted)
        #expect(call.state == .sent(first.note.id))
    }

    @Test func interruptionEndsAndSavesLikeEnd() async {
        let call = coordinator()
        await call.handle(.call)
        await call.interrupted()
        #expect(await recorder.stops == 1)
        #expect(await delivery.delivered.count == 1)
    }

    @Test func secondRequestWhileRecordingEndsTheCall() async {
        let call = coordinator()
        await call.handle(.call)
        await call.handle(.call)
        #expect(await recorder.startedURLs.count == 1)
        #expect(await recorder.stops == 1)
        #expect(await delivery.delivered.count == 1)
    }

    @Test func recorderFailureReportsFailedAndSavesNothing() async {
        await recorder.setFailStart(true)
        let call = coordinator()
        await call.handle(.call)
        guard case .failed = call.state else {
            Issue.record("expected failed, got \(call.state)")
            return
        }
        #expect(await outbox.pending().isEmpty)
    }

    @Test func endWithoutACallDoesNothing() async {
        let call = coordinator()
        await call.end()
        #expect(call.state == .idle)
        #expect(await recorder.stops == 0)
    }
}
