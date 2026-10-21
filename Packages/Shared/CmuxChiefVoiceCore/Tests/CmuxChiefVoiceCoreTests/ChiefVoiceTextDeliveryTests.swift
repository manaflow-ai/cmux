import CmuxChiefVoiceCore
import Foundation
import Testing

/// Collects what the text delivery hands to the Chief conversation.
@MainActor
final class SentTexts {
    var texts: [String] = []
    var reachable = true
}

@MainActor
@Suite("ChiefVoiceTextDelivery")
struct ChiefVoiceTextDeliveryTests {
    let sent = SentTexts()
    let audio = URL(fileURLWithPath: "/dev/null")

    func delivery() -> ChiefVoiceTextDelivery {
        let sent = sent
        return ChiefVoiceTextDelivery(
            send: { text in
                guard sent.reachable else { throw FakeError() }
                sent.texts.append(text)
            },
            noTranscript: { seconds in "Voice note (\(Int(seconds.rounded())) s), no transcript" }
        )
    }

    @Test func transcriptBecomesTheMessageText() async throws {
        let note = VoiceNote(mode: .call, createdAt: Date(), duration: 4, transcript: "Ship the build.")
        try await delivery().deliver(note, audioURL: audio)
        #expect(sent.texts == ["Ship the build."])
    }

    @Test func noteWithoutTranscriptSendsTheFallbackLine() async throws {
        let note = VoiceNote(mode: .voiceNote, createdAt: Date(), duration: 6.4)
        try await delivery().deliver(note, audioURL: audio)
        #expect(sent.texts == ["Voice note (6 s), no transcript"])
    }

    @Test func unreachableChiefThrowsSoTheNoteStaysInTheOutbox() async throws {
        sent.reachable = false
        let outbox = VoiceNoteOutbox(directory: temporaryDirectory())
        let call = ChiefCallCoordinator(recorder: FakeRecorder(), transcriber: FakeTranscriber(),
                                        microphone: FakeMicrophone(), delivery: delivery(), outbox: outbox)
        await call.handle(.call)
        await call.end()
        guard case .savedForLater = call.state else {
            Issue.record("expected savedForLater, got \(call.state)")
            return
        }
        #expect(await outbox.pending().count == 1)

        sent.reachable = true
        await call.drainOutbox()
        #expect(sent.texts == ["Hello Chief, ship the build."])
        #expect(await outbox.pending().isEmpty)
    }
}
