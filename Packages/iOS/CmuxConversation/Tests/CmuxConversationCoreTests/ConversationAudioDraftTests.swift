import Foundation
import Testing
@testable import CmuxConversationCore

/// The user, 2026-11-11: a recorded clip in Chief's composer disappeared when
/// the app went to the background and came back. A recording in review is a
/// ``ConversationAudioDraft``: kept on disk per conversation, and a recorder
/// built from it is back in review with the same audio.
@MainActor
@Suite struct ConversationAudioDraftTests {
    private func tone(seconds: Double) -> [Float] {
        (0 ..< Int(seconds * Double(ConversationWAV.sampleRate))).map { sin(Float($0) * 0.05) * 0.5 }
    }

    @Test func pcm16RoundTripsWithoutAVFoundation() throws {
        let samples = tone(seconds: 0.5)
        let decoded = try #require(ConversationWAV.decodePCM16(ConversationWAV.encode(samples)))
        #expect(decoded.count == samples.count)
        for (a, b) in zip(decoded, samples) { #expect(abs(a - b) < 0.001) }
        #expect(ConversationWAV.decodePCM16(Data("not a wav".utf8)) == nil)
        #expect(ConversationWAV.decodePCM16(Data()) == nil)
    }

    @Test func aRestoredRecorderIsInReviewWithTheSameAudio() throws {
        let wav = ConversationWAV.encode(tone(seconds: 3))
        let draft = ConversationAudioDraft(wav: wav, levels: Array(repeating: 0.4, count: 60), transcript: "On my way")
        #expect(abs(draft.duration - 3) < 0.001)
        let recorder = try #require(ConversationAudioRecorder(restoring: draft, input: .synthetic))
        #expect(recorder.state == .paused)
        #expect(abs(recorder.duration - 3) < 0.001)
        #expect(recorder.levels.count == 60)
        #expect(recorder.draft == draft, "kept again unchanged")
        let sent = try #require(recorder.finish())
        #expect(sent.data == wav)
        #expect(abs(sent.info.duration - 3) < 0.001)
        #expect(sent.info.transcript == "On my way")
    }

    @Test func continuingARestoredRecordingAppendsToIt() throws {
        let draft = ConversationAudioDraft(wav: ConversationWAV.encode(tone(seconds: 1)), levels: Array(repeating: 0.2, count: 20))
        let recorder = try #require(ConversationAudioRecorder(restoring: draft, input: .synthetic))
        try recorder.continueRecording()
        #expect(recorder.state == .recording)
        #expect(recorder.draft == nil, "nothing to keep mid-recording")
        recorder.pause()
        #expect(recorder.duration >= 1)
        #expect(recorder.draft != nil)
    }

    @Test func unreadableAudioRestoresNothing() {
        #expect(ConversationAudioRecorder(restoring: ConversationAudioDraft(wav: Data(), levels: []), input: .synthetic) == nil)
    }

    @Test func aStoreKeepsDraftsAcrossInstancesAndForgetsThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = ConversationAudioDraft(wav: ConversationWAV.encode(tone(seconds: 1)), levels: [0.1, 0.9])
        let first = ConversationAudioDraftStore(directory: directory)
        first.save(draft, key: "mac:A1/b")
        #expect(await first.load(key: "mac:A1/b") == draft, "from memory")
        await first.flush()

        // A new run (a relaunch) reads it off disk; another conversation has none.
        let relaunched = ConversationAudioDraftStore(directory: directory)
        #expect(await relaunched.load(key: "mac:A1/b") == draft)
        #expect(await relaunched.load(key: "cloud:other") == nil)

        relaunched.save(nil, key: "mac:A1/b")
        await relaunched.flush()
        #expect(await ConversationAudioDraftStore(directory: directory).load(key: "mac:A1/b") == nil, "sent or discarded stays gone")

        relaunched.save(draft, key: "k")
        relaunched.removeAll()
        await relaunched.flush()
        #expect(await relaunched.load(key: "k") == nil)
        #expect(await ConversationAudioDraftStore(directory: directory).load(key: "k") == nil, "sign-out removes every file")
    }

    /// Sign-out (``ConversationAudioDraftStore/removeAll()``): a recording that
    /// began before it is never saved again, so it cannot reach the next account.
    @Test func aSaveFromBeforeASignOutIsRefused() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationAudioDraftStore(directory: directory)
        let draft = ConversationAudioDraft(wav: ConversationWAV.encode(tone(seconds: 1)), levels: [0.3])
        let before = store.generation
        store.removeAll()
        store.save(draft, key: "acct|mac:A", generation: before)
        await store.flush()
        #expect(await store.load(key: "acct|mac:A") == nil, "the old account's recording was not kept")
        store.save(draft, key: "acct|mac:A", generation: store.generation)
        #expect(await store.load(key: "acct|mac:A") == draft, "a recording of the current account is kept")
    }
}
