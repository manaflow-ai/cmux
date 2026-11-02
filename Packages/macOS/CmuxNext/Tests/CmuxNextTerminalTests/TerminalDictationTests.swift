import AppKit
import CmuxNextDictation
@testable import CmuxNextTerminal
import Foundation
import Testing

/// Terminal dictation (#31862): finalized words go to the owner's paste, never a volatile
/// hypothesis; the preview shows over the pinned host while it listens and leaves when the
/// session ends; closing the host ends the session.
@Suite
@MainActor
struct TerminalDictationTests {
    @MainActor final class Pasted { var texts: [String] = [] }

    @Test func finalsReachThePasteAndThePreviewLeavesAtTheEnd() async throws {
        let engine = ScriptedTerminalTranscriber()
        let dictation = TerminalDictation(claims: DictationMicrophoneClaims()) {
            DictationSession(authorizer: GrantedTerminalAuthorizer(), makeTranscriber: { _ in engine })
        }
        let host = TerminalHostView()
        let pasted = Pasted()
        dictation.toggle(host: host) { pasted.texts.append($0) }
        #expect(dictation.isActive)
        let preview = try #require(host.topOverlay as? TerminalDictationPreview)
        // Events sent before the session's listen task opened the stream would be dropped.
        try await waitFor { engine.isStreaming }
        engine.emit(.partial("hel"))
        engine.emit(.final("hello"))
        engine.emit(.partial("wor"))
        // Only the words not pasted yet show: the session's volatile text, not "hello wor".
        try await waitFor { pasted.texts == ["hello"] && preview.accessibilityLabel() == "Listening… wor" }
        dictation.toggle(host: host) { _ in Issue.record("a stop never retargets the paste") }
        try await waitFor { !dictation.isActive }
        #expect(pasted.texts == ["hello", " wor"])
        #expect(host.topOverlay == nil)
        #expect(host.onClose == nil)
    }

    @Test func closingTheHostEndsTheSession() async throws {
        let engine = ScriptedTerminalTranscriber()
        let dictation = TerminalDictation(claims: DictationMicrophoneClaims()) {
            DictationSession(authorizer: GrantedTerminalAuthorizer(), makeTranscriber: { _ in engine })
        }
        let host = TerminalHostView()
        dictation.toggle(host: host) { _ in }
        #expect(dictation.isActive)
        try await waitFor { engine.isStreaming }
        host.onClose?()
        try await waitFor { !dictation.isActive }
        #expect(!dictation.isActive)
        #expect(host.topOverlay == nil)
        #expect(!dictation.stopIfActive())
    }

    private func waitFor(_ ready: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<300 where !ready() {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !ready() { Issue.record("timed out after 3 s", sourceLocation: sourceLocation) }
    }
}

private nonisolated struct GrantedTerminalAuthorizer: DictationAuthorizing {
    func microphoneAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestMicrophoneAuthorization() async -> Bool { true }
    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestSpeechRecognitionAuthorization() async -> Bool { true }
}

private nonisolated final class ScriptedTerminalTranscriber: SpeechTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    /// The session's listen task opened the stream: later events are buffered in order.
    var isStreaming: Bool { lock.withLock { continuation != nil } }

    func transcribe(locale: Locale) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DictationTranscriptionEvent.self, throwing: (any Error).self)
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func emit(_ event: DictationTranscriptionEvent) {
        lock.withLock { continuation }?.yield(event)
    }

    func finishTranscribing() async {
        lock.withLock { continuation }?.finish()
    }
}
