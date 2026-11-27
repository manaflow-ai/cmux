import Darwin
import CmuxNextDictation
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The native microphone owner supplies bytes, never an RPC pathname. File-backed recordings
/// retain the writer's identity and the same 24 MiB provider limit as inline recordings.
@Suite(.serialized) @MainActor
struct DictationProviderAudioTests {
    private struct Fixture {
        let folder: URL
        let file: URL
        let audio: DictationAudio

        init(size: Int) throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "voice-audio-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            file = folder.appending(path: "Recording.wav")
            try Data("RIFF".utf8).write(to: file)
            let writer = try FileHandle(forWritingTo: file)
            defer { try? writer.close() }
            try writer.truncate(atOffset: UInt64(size))
            let identity = try #require(DictationFileIdentity.of(descriptor: writer.fileDescriptor))
            audio = DictationAudio(file: file, byteCount: size, fileIdentity: identity)
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    private func rejects(_ audio: DictationAudio, code: String = "bad_response") async {
        do {
            _ = try await DictationProviderEngine.encodedAudio(audio)
            Issue.record("accepted an invalid recording")
        } catch let failure as DictationFailure {
            #expect(failure == .providerFailed(code: code, detail: ""))
        } catch {
            Issue.record("unexpected failure: \(error)")
        }
    }

    @Test func inlineAudioSendsItsBytes() async throws {
        let bytes = Data("RIFF1234WAVE".utf8)
        let encoded = try await DictationProviderEngine.encodedAudio(DictationAudio(byteCount: bytes.count, data: bytes))
        #expect(Data(base64Encoded: encoded) == bytes)
        await rejects(DictationAudio(byteCount: bytes.count + 1, data: bytes))
    }

    @Test func fullSizeFileRecordingFitsWithoutSendingAPath() async throws {
        let fixture = try Fixture(size: DictationProviderEngine.maximumAudioBytes)
        defer { fixture.remove() }
        let encoded = try await DictationProviderEngine.encodedAudio(fixture.audio)
        let decoded = try #require(Data(base64Encoded: encoded))
        #expect(decoded.count == DictationProviderEngine.maximumAudioBytes)
        #expect(decoded.prefix(4) == Data("RIFF".utf8))
        #expect(decoded.dropFirst(4).allSatisfy { $0 == 0 })
    }

    @Test func missingIdentityAndChangedLengthAreRejected() async throws {
        let fixture = try Fixture(size: 64)
        defer { fixture.remove() }
        await rejects(DictationAudio(file: fixture.file, byteCount: 64))
        var changed = fixture.audio
        changed.byteCount = 63
        await rejects(changed)
    }

    @Test func replacementAndSymlinkCannotSubstituteAnotherFile() async throws {
        let fixture = try Fixture(size: 64)
        defer { fixture.remove() }
        let original = fixture.folder.appending(path: "original.wav")
        try FileManager.default.moveItem(at: fixture.file, to: original)
        try Data(repeating: 42, count: 64).write(to: fixture.file)
        await rejects(fixture.audio)
        try FileManager.default.removeItem(at: fixture.file)
        // Even a link back to the correct inode must not be followed.
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: original)
        await rejects(fixture.audio)
    }

    @Test func fifoIsRejectedWithoutWaitingForAWriter() async throws {
        let fixture = try Fixture(size: 64)
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.file)
        #expect(mkfifo(fixture.file.path, 0o600) == 0)
        await rejects(fixture.audio)
    }

    @Test func sizeLimitAppliesBeforeEncodingInlineAndFileAudio() async throws {
        let size = DictationProviderEngine.maximumAudioBytes + 1
        let fixture = try Fixture(size: size)
        defer { fixture.remove() }
        await rejects(fixture.audio, code: "too_large")
        await rejects(DictationAudio(byteCount: size, data: Data(count: size)), code: "too_large")
    }
}
