import CmuxConversationCore
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileChief

/// Audio messages between the iPhone and the Mac's Chief (user, 2026-10-21:
/// "audio messages dont work on ios and dont send to macos"). A recording
/// left the phone as nothing: the Chief backends refused audio uploads, so
/// every audio message failed, and an audio part from the Mac showed as a
/// file. These run the backend against the fake Mac owner.
@Suite struct ChiefAudioTests {
    /// Speech-like mono samples: a 220 Hz tone that swells and fades.
    static func samples(seconds: Double) -> [Float] {
        let rate = Double(ConversationWAV.sampleRate)
        return (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            return Float(sin(2 * .pi * 220 * t) * 0.6 * abs(sin(.pi * t * 2)))
        }
    }

    static func recording(seconds: Double) -> Data {
        ConversationWAV.encode(samples(seconds: seconds))
    }

    /// The recording goes up as AAC (`audio/mp4`, about a tenth of the
    /// WAV the composer records) with its length, and the transcript goes in
    /// the same message as text, so the Mac and the Chief both read it.
    @Test func recordedAudioReachesTheMacWithItsLengthAndTranscript() async throws {
        let daemon = FakeDaemon()
        let backend = try await ChiefDaemonBackend.open(link: MockMacLink { _, request in daemon.respond(request) })
        var events = backend.events().makeAsyncIterator()
        _ = await events.next()

        let wav = Self.recording(seconds: 1.5)
        let info = ConversationAudioInfo(duration: 1.5, waveform: [0.2, 0.8, 0.4], transcript: "ship the fix")
        let uploaded = try await backend.uploadAudio(wav, mimeType: "audio/wav", info: info)
        #expect(uploaded.kind == .audio)

        let sent = try await backend.send(ConversationOutgoingDraft(clientMessageID: "v-1", text: "", replyToID: nil, attachmentIDs: [uploaded.id]))
        let parts = try #require(daemon.sentParts.last)
        #expect(parts.map { $0["type"] as? String } == ["attachment", "text"])
        #expect(parts[0]["mime_type"] as? String == "audio/mp4")
        #expect((parts[0]["name"] as? String)?.hasSuffix(".m4a") == true)
        let durationMS = try #require(parts[0]["duration_ms"] as? Int)
        #expect(abs(durationMS - 1500) < 100)
        let bytes = try #require(parts[0]["byte_count"] as? Int)
        #expect(bytes < wav.count / 2, "AAC, not the composer's WAV")
        #expect(parts[1]["text"] as? String == "ship the fix")

        // The phone's own bubble: an audio message whose transcript is the text.
        let audio = try #require(sent.audioAttachment?.audio)
        #expect(sent.text.isEmpty)
        #expect(audio.transcript == "ship the fix")
        #expect(abs(audio.duration - 1.5) < 0.1)
        #expect(!audio.waveform.isEmpty)
        backend.close()
    }

    /// The path the record button takes: the store's `sendAudio` ends
    /// delivered, never "Not Delivered".
    @MainActor @Test func storeDeliversARecordedAudioMessage() async throws {
        let daemon = FakeDaemon()
        let backend = try await ChiefDaemonBackend.open(link: MockMacLink { _, request in daemon.respond(request) })
        let store = ConversationStore(backend: backend)
        store.start()
        try await waitUntil("the store to connect") { store.meID != nil }

        let info = ConversationAudioInfo(duration: 1.2, waveform: [0.5, 0.9], transcript: "hello Chief")
        #expect(store.sendAudio(data: Self.recording(seconds: 1.2), info: info) != nil)
        try await waitUntil("the audio message to be sent") {
            store.messages.contains { $0.senderID == ChiefIdentity.standard.meID && $0.seq != nil && $0.audioAttachment != nil }
        }
        let mine = store.messages.filter { $0.senderID == ChiefIdentity.standard.meID && $0.audioAttachment != nil }
        #expect(mine.count == 1)
        #expect(mine.first?.delivery?.isFailed == false)
        #expect(daemon.sentParts.last?.first?["mime_type"] as? String == "audio/mp4")
        backend.close()
    }

    /// An audio part on the Mac (a message sent earlier from this phone, or a
    /// file the Mac attached) reads back as an audio message: its length, a
    /// waveform from its bytes, and the text of the message as its transcript.
    @Test func audioFromTheMacReadsAsAnAudioMessage() async throws {
        let daemon = FakeDaemon()
        let wav = Self.recording(seconds: 2)
        daemon.seed(author: "user_local", parts: [
            ["type": "attachment", "hash": "voicememo", "name": "Voice Message.wav", "mime_type": "audio/wav",
             "byte_count": wav.count, "duration_ms": 2000],
            ["type": "text", "text": "check the build"],
        ], bytes: ["voicememo": wav])
        let backend = try await ChiefDaemonBackend.open(link: MockMacLink { _, request in daemon.respond(request) })
        var events = backend.events().makeAsyncIterator()
        _ = await events.next()

        let page = try await backend.history(beforeSeq: nil, limit: 50)
        let message = try #require(page.messages.first { $0.clientMessageID?.hasPrefix("seed-") == true })
        let attachment = try #require(message.audioAttachment)
        #expect(attachment.kind == .audio)
        #expect(attachment.localData == wav)
        let audio = try #require(attachment.audio)
        #expect(abs(audio.duration - 2) < 0.05)
        #expect(audio.transcript == "check the build")
        #expect(audio.waveform.count > 8)
        #expect(audio.waveform.contains { $0 > 0.3 }, "levels from the real samples, not a flat line")
        #expect(message.text.isEmpty, "the transcript shows inside the audio bubble, not as a second bubble")
        backend.close()
    }
}
