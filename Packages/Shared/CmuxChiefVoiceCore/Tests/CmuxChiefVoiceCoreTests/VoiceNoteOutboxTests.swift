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

    @Test func accountScopedOutboxesNeverSeeAnotherAccountsPendingNotes() async throws {
        let root = temporaryDirectory()
        let first = VoiceNoteOutbox(rootDirectory: root, accountID: "account-a")
        let second = VoiceNoteOutbox(rootDirectory: root, accountID: "account-b")
        let note = VoiceNote(mode: .voiceNote, createdAt: Date(timeIntervalSince1970: 100), transcript: "private")

        try await first.save(note)

        #expect(await first.pending() == [note])
        #expect(await second.pending().isEmpty)
    }

    @Test func accountScopedOutboxDiscardsAmbiguousLegacyNotes() async throws {
        let root = temporaryDirectory()
        try FileManager().createDirectory(at: root, withIntermediateDirectories: true)
        let record = root.appendingPathComponent("legacy.json")
        let audio = root.appendingPathComponent("legacy.m4a")
        try Data("metadata".utf8).write(to: record)
        try Data("audio".utf8).write(to: audio)

        _ = VoiceNoteOutbox(rootDirectory: root, accountID: "account-a")

        #expect(!FileManager().fileExists(atPath: record.path))
        #expect(!FileManager().fileExists(atPath: audio.path))
    }
}
