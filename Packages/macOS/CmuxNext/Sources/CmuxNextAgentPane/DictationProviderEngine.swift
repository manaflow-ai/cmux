public import CmuxNextDictation
public import CmuxNextSettings
import Foundation

/// cmux's own dictation (agent pane, Home, terminal) with the person's own provider
/// (`agentPane.dictationEngine`): `onDevice` keeps Apple's engine, as before; any other engine
/// records the session and on stop has the LOCAL acpmux transcribe it (`_acpmux/voice/transcribe`),
/// which reads the engine settings and the Keychain key itself, so no key passes through here.
/// The engine is read when each dictation starts, so a change applies to the next one.
/// Leo, 2026-11-22: "people should be able to add their own api keys/whatever and toggle that
/// voice mode and whatever to link up to their provider of choice. just like our mic thing."
public struct DictationProviderEngine {
    public init() {}
    /// Has the surfaces that share `claims`' microphone dictate with the engine `settings` names.
    /// - Parameter environment: The app's acpmux, asked as each dictation starts (nil: on-device).
    @MainActor
    public static func follow(
        _ settings: SettingsController,
        claims: DictationMicrophoneClaims = .shared,
        environment: @escaping @MainActor () -> AcpmuxEnvironment?
    ) {
        claims.providerTranscription = { [weak settings] in
            guard let settings,
                  let environment = environment() else { return nil }
            let composer = settings.snapshot.agentPaneComposer
            guard composer.dictationEngine != .onDevice else { return nil }
            let capturedSettings = [
                "engine": composer.dictationEngine.rawValue,
                "url": composer.dictationEngineURL,
                "model": composer.dictationEngineModel
            ]
            return { audio, locale in
                try await transcribe(audio, locale: locale, environment: environment, settings: capturedSettings)
            }
        }
    }

    /// One recording through acpmux: its bytes inline, the language as BCP 47;
    /// the answer is `{text}` or `{error: {code, detail}}`, a failure is ``DictationFailure/providerFailed(code:detail:)``.
    nonisolated static func transcribe(_ audio: DictationAudio, locale: Locale, environment: AcpmuxEnvironment, settings: [String: String]? = nil) async throws -> String {
        var params: [String: any Sendable] = ["language": locale.identifier(.bcp47)]
        if let settings { params["settings"] = settings }
        params["audio"] = try await encodedAudio(audio)
        try Task.checkCancellation()
        let reply: Data
        do {
            reply = try await environment.harness(.voiceTranscribe, params: params)
        } catch let error as AcpmuxRPCError {
            throw DictationFailure.providerFailed(code: error.isUnreachable ? "offline" : "provider_error", detail: "")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The socket itself failed (no daemon, closed, too long a path).
            throw DictationFailure.providerFailed(code: "offline", detail: "")
        }
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw DictationFailure.providerFailed(code: "bad_response", detail: "")
        }
        if let text = object["text"] as? String { return text }
        let failure = object["error"] as? [String: Any]
        throw DictationFailure.providerFailed(code: failure?["code"] as? String ?? "bad_response",
                                              detail: failure?["detail"] as? String ?? "")
    }

    /// Matches cmux-voice's MAX_AUDIO_BYTES. Its base64 fits the Unix socket's 64 MiB
    /// inbound line limit. Paths never cross that RPC boundary: only the microphone owner
    /// can open the recording, using the identity captured by its writer.
    nonisolated static let maximumAudioBytes = 24 * 1024 * 1024

    @concurrent static func encodedAudio(_ audio: DictationAudio) async throws -> String {
        try Task.checkCancellation()
        let invalid = DictationFailure.providerFailed(code: "bad_response", detail: "")
        let tooLarge = DictationFailure.providerFailed(code: "too_large", detail: "")
        if let data = audio.data {
            guard data.count <= maximumAudioBytes else { throw tooLarge }
            guard data.count == audio.byteCount else { throw invalid }
            return data.base64EncodedString()
        }
        guard let file = audio.file, let identity = audio.fileIdentity,
              let recording = AgentPaneDictationUpload.Recording.open(
                AgentPaneIssuedRecording(file: file, identity: identity)
              ) else { throw invalid }
        defer { recording.close() }
        guard recording.size <= maximumAudioBytes else { throw tooLarge }
        guard recording.size >= 0, recording.size == audio.byteCount else { throw invalid }
        var bytes = Data()
        bytes.reserveCapacity(recording.size)
        while bytes.count < recording.size {
            try Task.checkCancellation()
            let count = min(256 * 1024, recording.size - bytes.count)
            guard let chunk = recording.read(at: bytes.count, count: count),
                  !chunk.isEmpty else { throw invalid }
            bytes.append(chunk)
        }
        // Refuse growth during the read, probing only one byte beyond the bounded recording.
        guard recording.read(at: bytes.count, count: 1)?.isEmpty == true else { throw invalid }
        try Task.checkCancellation()
        return bytes.base64EncodedString()
    }
}
