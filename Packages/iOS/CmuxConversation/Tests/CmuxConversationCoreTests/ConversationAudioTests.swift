import Foundation
import Testing
@testable import CmuxConversationCore

extension ScriptedBackend: ConversationAudioBackend {
    func uploadAudioRecording(_ data: Data, mimeType: String, info: ConversationAudioInfo) async throws -> ConversationAttachment {
        ConversationAttachment(id: "aud", kind: .audio, width: 0, height: 0, url: nil, audio: info)
    }

    func keepAudioMessage(messageID: String) async throws -> ConversationMessage {
        throw ConversationBackendError(code: -1, message: "unsupported")
    }

    func markAudioPlayed(messageID: String) async {}
}

@MainActor
@Suite struct ConversationAudioTests {
    @Test func wireDecodesAudioAttachments() throws {
        let base = URL(string: "http://127.0.0.1:4870")!
        let attachment = try #require(WireDecoding.attachment([
            "id": "aud_1",
            "kind": "audio",
            "durationMs": 4250,
            "waveform": [0, 50, 100],
            "transcript": "On my way",
            "expiresAt": 1_000_000,
            "url": "/media/aud_1.wav",
        ], base: base))
        #expect(attachment.kind == .audio)
        #expect(attachment.url?.absoluteString == "http://127.0.0.1:4870/media/aud_1.wav")
        let audio = try #require(attachment.audio)
        #expect(audio.duration == 4.25)
        #expect(audio.waveform == [0, 0.5, 1])
        #expect(audio.transcript == "On my way")
        #expect(audio.expiresAt == Date(timeIntervalSince1970: 1000))
        #expect(!audio.isKept)

        let image = try #require(WireDecoding.attachment(["id": "img", "width": 10, "height": 20], base: base))
        #expect(image.kind == .image)
        #expect(image.audio == nil)
    }

    @Test func waveformResamplesByBucketPeak() {
        let info = ConversationAudioInfo(duration: 1, waveform: [0.1, 0.9, 0.2, 0.3, 0.8, 0.0])
        #expect(info.levels(count: 3) == [0.9, 0.3, 0.8])
        #expect(info.levels(count: 6) == info.waveform)
        #expect(ConversationAudioInfo.resample([], count: 2) == [0, 0])
        // Upsampling repeats rather than inventing peaks.
        #expect(ConversationAudioInfo.resample([0.2, 0.6], count: 4) == [0.2, 0.2, 0.6, 0.6])
    }

    @Test func wavRoundTripsThroughAVFoundation() throws {
        let samples = ConversationSyntheticSpeech.samples(seconds: 0.5, seed: 7)
        let data = ConversationWAV.encode(samples)
        #expect(data.count == 44 + samples.count * 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-wav-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let decoded = try ConversationWAV.decode(contentsOf: url)
        #expect(abs(decoded.count - samples.count) < 64)
        let levels = ConversationWAV.levels(decoded, bucket: 800)
        #expect(levels.contains { $0 > 0.5 })
    }

    @Test func sendAudioShowsTheRecordingAtOnceThenUploadsAndAcks() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "voice-1" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        backend.holdSend = true
        let data = ConversationWAV.encode(ConversationSyntheticSpeech.samples(seconds: 1, seed: 1))
        let info = ConversationAudioInfo(duration: 1, waveform: [0.2, 0.7], transcript: "hi")
        let rowID = try #require(store.sendAudio(data: data, info: info))
        let pending = try #require(store.message(rowID: rowID))
        #expect(pending.delivery == .sending)
        #expect(pending.audioAttachment?.localData == data)
        #expect(pending.audioAttachment?.audio?.transcript == "hi")
        #expect(pending.text.isEmpty)

        backend.releaseSend()
        try await waitUntil { store.message(rowID: rowID)?.seq != nil }
        #expect(backend.sentClientIDs == ["voice-1"])
    }

    @Test func keepClearsExpiryLocally() async throws {
        let backend = ScriptedBackend(total: 1)
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        var voice = backend.makeMessage(seq: 2, sender: "lc")
        voice.text = ""
        voice.attachments = [ConversationAttachment(
            id: "a", kind: .audio, width: 0, height: 0, url: nil,
            audio: ConversationAudioInfo(duration: 3, waveform: [0.5], expiresAt: Date().addingTimeInterval(120))
        )]
        store.apply(.message(voice, eventSeq: 1))
        store.keepAudio(messageID: "m2")
        let kept = try #require(store.message(id: "m2")?.audioAttachment?.audio)
        #expect(kept.isKept)
        #expect(kept.expiresAt == nil)
    }
}
