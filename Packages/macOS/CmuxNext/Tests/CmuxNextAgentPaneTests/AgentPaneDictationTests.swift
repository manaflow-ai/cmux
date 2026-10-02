import AppKit
import CmuxNextDictation
import Foundation
import Testing
@testable import CmuxNextAgentPane

private struct GrantingAuthorizer: DictationAuthorizing {
    func microphoneAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestMicrophoneAuthorization() async -> Bool { true }
    func speechRecognitionAuthorization() async -> DictationAuthorizationStatus { .authorized }
    func requestSpeechRecognitionAuthorization() async -> Bool { true }
}

/// Listens until finished; the finish flushes nothing.
private actor SilentEngine: SpeechTranscribing {
    private var continuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?

    func transcribe(locale: Locale) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        self.continuation = continuation
        return stream
    }

    func finishTranscribing() async { continuation?.finish() }
    func say(_ text: String) { continuation?.yield(.final(text)) }
}

@MainActor
@Suite struct AgentPaneDictationTests {
    private static func decode(_ method: String, _ params: [String: Any]? = nil) -> AgentPaneRequest {
        var body: [String: Any] = ["id": "1", "method": method]
        if let params { body["params"] = params }
        return AgentPaneRequest(body: body)
    }

    @Test func decodesEveryDictationRequest() {
        #expect(Self.decode("dictation.toggle") == .dictation(.toggle))
        #expect(Self.decode("dictation.start") == .dictation(.start))
        #expect(Self.decode("dictation.stop") == .dictation(.stop))
        #expect(Self.decode("dictation.cancel") == .dictation(.cancel))
        #expect(Self.decode("dictation.openSettings", ["permission": "microphone"]) == .dictation(.openSettings(.microphone)))
        #expect(Self.decode("dictation.openSettings", ["permission": "speechRecognition"]) == .dictation(.openSettings(.speechRecognition)))
        #expect(Self.decode("dictation.openSettings", ["permission": "camera"]) == .unsupported("dictation.openSettings"))
        #expect(Self.decode("dictation.openSettings") == .unsupported("dictation.openSettings"))
    }

    @Test func modelForwardsDictationOnlyWithAHandler() async {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        let refused = await model.respond(to: .dictation(.toggle))
        #expect(refused["ok"] as? Bool == false)
        var received: [AgentPaneDictationCommand] = []
        model.onDictation = { received.append($0) }
        let reply = await model.respond(to: .dictation(.cancel))
        #expect(reply["ok"] as? Bool == true)
        #expect(received == [.cancel])
    }

    @Test func payloadCarriesStateTextAndLevel() {
        let value = AgentPaneDictation.payload(DictationUpdate(phase: .listening, text: "fix the bug", level: 0.4567))
        #expect(value["state"] as? String == "listening")
        #expect(value["text"] as? String == "fix the bug")
        #expect(value["level"] as? Double == 0.457)
        #expect(value["cancelled"] as? Bool == false)
        #expect(value["message"] == nil)
    }

    @Test func deniedPayloadNamesThePermissionAndTheSettingsLink() {
        let value = AgentPaneDictation.payload(DictationUpdate(phase: .denied(.microphone)))
        #expect(value["state"] as? String == "denied")
        #expect(value["permission"] as? String == "microphone")
        #expect((value["message"] as? String)?.isEmpty == false)
        #expect(value["settingsLabel"] as? String == AgentPaneDictation.openSettingsTitle)
    }

    @Test func failedPayloadHasAMessage() {
        let value = AgentPaneDictation.payload(DictationUpdate(phase: .failed(.audioCaptureFailed("x"))))
        #expect(value["state"] as? String == "failed")
        #expect(value["message"] as? String == AgentPaneDictation.failureMessage(.audioCaptureFailed("x")))
    }

    @Test func scriptCallsTheOptionalPageHook() throws {
        let script = try #require(AgentPaneDictation.script(DictationUpdate(phase: .idle, cancelled: true)))
        #expect(script.hasPrefix("window.cmuxAcpmuxBridge?.dictation?.({"))
        #expect(script.contains("\"cancelled\":true"))
    }

    @Test func settingsLinksOpenThePrivacyPanes() {
        #expect(AgentPaneDictation.settingsURL(.microphone)?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #expect(AgentPaneDictation.settingsURL(.speechRecognition)?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        var opened: [URL] = []
        let dictation = AgentPaneDictation(evaluate: { _ in })
        dictation.open = { opened.append($0) }
        dictation.handle(.openSettings(.microphone))
        #expect(opened == [AgentPaneDictation.settingsURL(.microphone)])
    }

    /// Text reaches the page through the bridge hook, and a cancel tells it
    /// to drop the text.
    @Test func sessionUpdatesReachThePage() async {
        let engine = SilentEngine()
        var scripts: [String] = []
        let dictation = AgentPaneDictation(evaluate: { scripts.append($0) }) {
            DictationSession(authorizer: GrantingAuthorizer(), makeTranscriber: { _ in engine })
        }
        dictation.handle(.toggle)
        await until { dictation.phase == .listening }
        await engine.say("hello")
        await until { scripts.last?.contains("\"text\":\"hello\"") == true }
        dictation.handle(.cancel)
        #expect(dictation.phase == .idle)
        #expect(scripts.last?.contains("\"cancelled\":true") == true)
    }

    /// One microphone at a time: starting a second pane stops the first,
    /// which keeps its text.
    @Test func startingAnotherPaneStopsTheFirst() async {
        let first = SilentEngine(), second = SilentEngine()
        var firstScripts: [String] = []
        let a = AgentPaneDictation(evaluate: { firstScripts.append($0) }) {
            DictationSession(authorizer: GrantingAuthorizer(), makeTranscriber: { _ in first })
        }
        let b = AgentPaneDictation(evaluate: { _ in }) {
            DictationSession(authorizer: GrantingAuthorizer(), makeTranscriber: { _ in second })
        }
        a.handle(.start)
        await until { a.phase == .listening }
        await first.say("kept")
        await until { firstScripts.last?.contains("kept") == true }
        b.handle(.start)
        await until { a.phase == .idle && b.phase == .listening }
        #expect(firstScripts.last?.contains("\"cancelled\":false") == true)
        #expect(firstScripts.last?.contains("\"text\":\"kept\"") == true)
        b.close()
    }

    /// Holding the shortcut repeats its key down; only the first press
    /// toggles, so a held key keeps listening.
    @Test func keyRepeatsWhileHeldDoNotToggle() async throws {
        let engine = SilentEngine()
        let dictation = AgentPaneDictation(evaluate: { _ in }) {
            DictationSession(authorizer: GrantingAuthorizer(), makeTranscriber: { _ in engine })
        }
        func key(repeat: Bool) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control, .command], timestamp: 1, windowNumber: 0,
                context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: repeat, keyCode: 9
            ))
        }
        dictation.toggle(from: try key(repeat: false))
        await until { dictation.phase == .listening }
        dictation.toggle(from: try key(repeat: true))
        dictation.toggle(from: try key(repeat: true))
        #expect(dictation.phase == .listening)
        dictation.close()
        #expect(dictation.phase == .idle)
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("condition never held")
    }
}
