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
                  settings.snapshot.agentPaneComposer.dictationEngine != .onDevice,
                  let environment = environment() else { return nil }
            return { audio, locale in try await transcribe(audio, locale: locale, environment: environment) }
        }
    }

    /// One recording through acpmux: its bytes inline (or its file's path), the language as BCP 47;
    /// the answer is `{text}` or `{error: {code, detail}}`, a failure is ``DictationFailure/providerFailed(code:detail:)``.
    nonisolated static func transcribe(_ audio: DictationAudio, locale: Locale, environment: AcpmuxEnvironment) async throws -> String {
        var params: [String: any Sendable] = ["language": locale.identifier(.bcp47)]
        if let data = audio.data {
            params["audio"] = data.base64EncodedString()
        } else if let file = audio.file {
            params["path"] = file.path
        } else {
            throw DictationFailure.providerFailed(code: "bad_response", detail: "")
        }
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
}
