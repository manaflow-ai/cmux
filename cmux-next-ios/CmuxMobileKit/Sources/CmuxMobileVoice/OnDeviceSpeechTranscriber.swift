#if os(iOS)
public import CmuxChiefVoiceCore
public import Foundation
import os
import Speech

/// Transcribes a recorded note with `SFSpeechRecognizer`, on device only.
///
/// Audio never leaves the phone for recognition: when the recognizer for
/// `locale` has no on-device model the transcriber throws
/// ``OnDeviceSpeechTranscriberError/onDeviceUnavailable`` and the note is sent
/// as audio without text. No server recognizer and no paid API.
public struct OnDeviceSpeechTranscriber: VoiceTranscribing {
    private let locale: Locale

    /// Creates a transcriber for `locale`.
    /// - Parameter locale: The spoken language (the app passes `Locale.current`).
    public init(locale: Locale) {
        self.locale = locale
    }

    /// Transcribes the file at `url`.
    /// - Throws: ``OnDeviceSpeechTranscriberError`` or a recognition error.
    public func transcribe(fileAt url: URL) async throws -> String {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw OnDeviceSpeechTranscriberError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw OnDeviceSpeechTranscriberError.unavailable
        }
        guard recognizer.supportsOnDeviceRecognition else { throw OnDeviceSpeechTranscriberError.onDeviceUnavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        // One-shot resume guard: the result handler can fire for a final result
        // and an error; a synchronous compare-and-set (CLAUDE.md lock carve-out).
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let text: String = try await withCheckedThrowingContinuation { continuation in
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                    continuation.resume(throwing: error)
                }
            }
        }
        // The recognizer must outlive its task, which does not retain it.
        withExtendedLifetime(recognizer) {}
        return text
    }
}

/// Why ``OnDeviceSpeechTranscriber`` produced no text.
public enum OnDeviceSpeechTranscriberError: Error, Sendable {
    /// The user has not allowed speech recognition.
    case notAuthorized
    /// No recognizer for the locale, or it is busy.
    case unavailable
    /// The locale has no on-device model; server recognition is not used.
    case onDeviceUnavailable
}
#endif
