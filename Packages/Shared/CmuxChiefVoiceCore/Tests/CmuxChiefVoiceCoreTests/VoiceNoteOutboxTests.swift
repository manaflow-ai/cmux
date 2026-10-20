import CmuxChiefVoiceCore
import Foundation
import Testing

@Suite("VoiceNoteOutbox")
struct VoiceNoteOutboxTests {
    @Test func notesSurviveANewOutboxOverTheSameDirectory() async throws {
        let directory = temporaryDirectory()
        let older = VoiceNote(mode: .call, createdAt: Date(timeIntervalSince1970: 100), duration: 2)
        let newer = VoiceNote(mode: .voiceNote, createdAt: Date(timeIntervalSince1970: 200), transcript: "hi")
        let first = VoiceNoteOutbox(directory: directory)
        try await first.save(newer)
        try await first.save(older)

        let relaunched = VoiceNoteOutbox(directory: directory)
        #expect(await relaunched.pending() == [older, newer])
    }

    @Test func removeDeletesRecordAndAudio() async throws {
        let directory = temporaryDirectory()
        let outbox = VoiceNoteOutbox(directory: directory)
        let note = VoiceNote(mode: .call, createdAt: Date())
        try await outbox.save(note)
        try Data("audio".utf8).write(to: outbox.audioURL(for: note.id))
        await outbox.remove(note.id)
        #expect(await outbox.pending().isEmpty)
        #expect(!FileManager().fileExists(atPath: outbox.audioURL(for: note.id).path))
    }
}
