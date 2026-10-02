import AppKit
import CmuxNextDictation
import Foundation
import Testing
@testable import CmuxNextAgentPane

private nonisolated struct GrantingAuthorizer: DictationAuthorizing {
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

    private(set) var finishes = 0
    func finishTranscribing() async {
        finishes += 1
        continuation?.finish()
    }
    func say(_ text: String) { continuation?.yield(.final(text)) }
    func hear(_ text: String) { continuation?.yield(.partial(text)) }
}

@MainActor
@Suite(.serialized) struct AgentPaneDictationTests {
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

    /// A pane with its own microphone, so parallel tests never stop each other.
    private static func pane(
        _ engine: SilentEngine, microphone: DictationMicrophone = DictationMicrophone(), scripts: @escaping (String) -> Void = { _ in }
    ) -> AgentPaneDictation {
        _ = NSApplication.shared
        let dictation = AgentPaneDictation(evaluate: scripts, microphone: microphone) {
            DictationSession(authorizer: GrantingAuthorizer(), makeTranscriber: { _ in engine })
        }
        dictation.sleepNotifications = NotificationCenter()
        dictation.now = { 100 }
        return dictation
    }

    /// The Toggle Dictation chord (Ctrl-Cmd-V) going down or up at `time`.
    private static func key(
        _ type: NSEvent.EventType, at time: TimeInterval, isRepeat: Bool = false, modifiers: NSEvent.ModifierFlags = [.control, .command]
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers, timestamp: time, windowNumber: 0,
            context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: isRepeat, keyCode: 9
        ))
    }

    /// Text reaches the page through the bridge hook, and a cancel tells it
    /// to drop the text.
    @Test func sessionUpdatesReachThePage() async {
        let engine = SilentEngine()
        var scripts: [String] = []
        let dictation = Self.pane(engine) { scripts.append($0) }
        dictation.handle(.toggle)
        await until { dictation.phase == .listening }
        await engine.say("hello")
        await until { scripts.last?.contains("\"text\":\"hello\"") == true }
        dictation.handle(.cancel)
        #expect(dictation.phase == .idle)
        #expect(scripts.last?.contains("\"cancelled\":true") == true)
        await until { await engine.finishes >= 1 && !dictation.holdsResources }
    }

    /// One microphone at a time: starting a second pane stops the first,
    /// which keeps its text.
    @Test func startingAnotherPaneStopsTheFirst() async {
        let first = SilentEngine(), second = SilentEngine()
        let microphone = DictationMicrophone()
        var firstScripts: [String] = []
        let a = Self.pane(first, microphone: microphone) { firstScripts.append($0) }
        let b = Self.pane(second, microphone: microphone)
        a.handle(.start)
        await until { a.phase == .listening }
        await first.say("kept")
        await until { firstScripts.last?.contains("kept") == true }
        b.handle(.start)
        await until { a.phase == .idle && b.phase == .listening }
        #expect(firstScripts.last?.contains("\"cancelled\":false") == true)
        #expect(firstScripts.last?.contains("\"text\":\"kept\"") == true)
        #expect(microphone.listening === b)
        b.close()
        await until { !a.holdsResources && !b.holdsResources }
        await until { await first.finishes >= 1 }
        await until { await second.finishes >= 1 }
    }

    /// The shortcut pressed outside an agent chat stops the pane that still
    /// listens; with none listening there is nothing to stop.
    @Test func theSharedMicrophoneStopsWhicheverPaneListens() async {
        let engine = SilentEngine()
        let microphone = DictationMicrophone()
        #expect(!microphone.stopListening())
        let dictation = Self.pane(engine, microphone: microphone)
        dictation.handle(.start)
        await until { dictation.phase == .listening }
        #expect(microphone.stopListening())
        await until { dictation.phase == .idle && !dictation.holdsResources }
        #expect(microphone.listening == nil)
        #expect(!microphone.stopListening())
    }

    /// Holding the shortcut repeats its key down; only the first press
    /// toggles, so a held key keeps listening.
    @Test func keyRepeatsWhileHeldDoNotToggle() async throws {
        let engine = SilentEngine()
        let dictation = Self.pane(engine)
        dictation.toggle(from: try Self.key(.keyDown, at: 100))
        await until { dictation.phase == .listening }
        dictation.toggle(from: try Self.key(.keyDown, at: 100.1, isRepeat: true))
        dictation.toggle(from: try Self.key(.keyDown, at: 100.2, isRepeat: true))
        #expect(dictation.phase == .listening)
        dictation.close()
        #expect(dictation.phase == .idle)
        await until { !dictation.holdsResources }
    }

    /// Push-to-talk: released after a moment, it stops mid-phrase and keeps
    /// the words heard so far.
    @Test func releasingAHeldShortcutStopsAndKeepsTheWords() async throws {
        let engine = SilentEngine()
        var scripts: [String] = []
        let dictation = Self.pane(engine) { scripts.append($0) }
        dictation.toggle(from: try Self.key(.keyDown, at: 100))
        await until { dictation.phase == .listening }
        await engine.say("open the")
        await engine.hear("settings")
        await until { scripts.last?.contains("open the settings") == true }
        dictation.keyUp(try Self.key(.keyUp, at: 101))
        await until { dictation.phase == .idle }
        #expect(scripts.last?.contains("\"state\":\"idle\"") == true)
        #expect(scripts.last?.contains("\"text\":\"open the settings\"") == true)
        await until { !dictation.holdsResources }
    }

    /// People let go of a chord in any order: a modifier coming up first
    /// is the release, and the key's own key-up after it changes nothing.
    @Test func releasingAModifierFirstStopsAndKeepsTheWords() async throws {
        let engine = SilentEngine()
        var scripts: [String] = []
        let dictation = Self.pane(engine) { scripts.append($0) }
        dictation.toggle(from: try Self.key(.keyDown, at: 100))
        await until { dictation.phase == .listening }
        await engine.hear("half a phrase")
        await until { scripts.last?.contains("half a phrase") == true }
        // Shift going down mid-hold is not a release.
        dictation.flagsChanged(try Self.key(.flagsChanged, at: 100.5, modifiers: [.control, .command, .shift]))
        #expect(dictation.phase == .listening)
        dictation.flagsChanged(try Self.key(.flagsChanged, at: 101, modifiers: [.command]))
        dictation.keyUp(try Self.key(.keyUp, at: 101.02, modifiers: []))
        await until { dictation.phase == .idle && !dictation.holdsResources }
        #expect(scripts.last?.contains("\"text\":\"half a phrase\"") == true)
    }

    /// An extra modifier pressed during the hold does not keep the release
    /// from stopping.
    @Test func releasingWithAnExtraModifierDownStillStops() async throws {
        let engine = SilentEngine()
        let dictation = Self.pane(engine)
        dictation.toggle(from: try Self.key(.keyDown, at: 100))
        await until { dictation.phase == .listening }
        dictation.flagsChanged(try Self.key(.flagsChanged, at: 100.5, modifiers: [.control, .command, .option]))
        #expect(dictation.phase == .listening)
        dictation.keyUp(try Self.key(.keyUp, at: 101, modifiers: [.control, .command, .option]))
        await until { dictation.phase == .idle && !dictation.holdsResources }
    }

    /// A quick tap that lets go of a modifier first is still a tap.
    @Test func aQuickTapReleasingAModifierFirstKeepsListening() async throws {
        let engine = SilentEngine()
        let dictation = Self.pane(engine)
        dictation.toggle(from: try Self.key(.keyDown, at: 100))
        await until { dictation.phase == .listening }
        dictation.flagsChanged(try Self.key(.flagsChanged, at: 100.1, modifiers: [.control]))
        dictation.keyUp(try Self.key(.keyUp, at: 100.12, modifiers: []))
        #expect(dictation.phase == .listening)
        dictation.close()
        await until { !dictation.holdsResources }
    }

    /// A quick tap is a toggle: dictation keeps listening after the release.
    @Test func aQuickTapKeepsListening() async throws {
        let engine = SilentEngine()
        let dictation = Self.pane(engine)
        dictation.toggle(from: try Self.key(.keyDown, at: 100))
        await until { dictation.phase == .listening }
        dictation.keyUp(try Self.key(.keyUp, at: 100.1))
        #expect(dictation.phase == .listening)
        dictation.toggle(from: try Self.key(.keyDown, at: 102))
        await until { dictation.phase == .idle && !dictation.holdsResources }
    }

    /// The press's release went elsewhere (a permission prompt, another
    /// app): typing a plain "v" later must not stop dictation.
    @Test func aLaterPlainKeyIsNotTheShortcutsRelease() async throws {
        let engine = SilentEngine()
        let dictation = Self.pane(engine)
        dictation.toggle(from: try Self.key(.keyDown, at: 100))
        await until { dictation.phase == .listening }
        dictation.keyUp(try Self.key(.keyUp, at: 103, modifiers: []))
        #expect(dictation.phase == .listening)
        // The hold is over: a later chord release does nothing either.
        dictation.keyUp(try Self.key(.keyUp, at: 104))
        #expect(dictation.phase == .listening)
        dictation.close()
        await until { !dictation.holdsResources }
    }

    /// A stale event behind a palette, menu or CLI call is a plain toggle:
    /// no hold, and a stale repeat does not swallow the command.
    @Test func staleEventsArePlainToggles() async throws {
        let engine = SilentEngine()
        let dictation = Self.pane(engine)
        dictation.toggle(from: try Self.key(.keyDown, at: 50, isRepeat: true))
        await until { dictation.phase == .listening }
        dictation.keyUp(try Self.key(.keyUp, at: 101))
        #expect(dictation.phase == .listening)
        // The palette's Return carries no modifier chord.
        dictation.toggle(from: try Self.key(.keyDown, at: 100, modifiers: []))
        await until { dictation.phase == .idle && !dictation.holdsResources }
    }

    /// The Mac going to sleep stops listening and keeps the words; the
    /// observer exists only while a session runs.
    @Test func sleepStopsListening() async {
        let engine = SilentEngine()
        var scripts: [String] = []
        let dictation = Self.pane(engine) { scripts.append($0) }
        #expect(!dictation.holdsResources)
        dictation.handle(.start)
        await until { dictation.phase == .listening }
        #expect(dictation.holdsResources)
        await engine.say("before sleep")
        await until { scripts.last?.contains("before sleep") == true }
        dictation.sleepNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        await until { dictation.phase == .idle && !dictation.holdsResources }
        #expect(scripts.last?.contains("\"text\":\"before sleep\"") == true)
        #expect(await engine.finishes >= 1)
    }

    /// Closing the pane mid-dictation drops the session and lets go of the
    /// microphone; nothing is left behind.
    @Test func closingMidDictationReleasesEverything() async throws {
        let engine = SilentEngine()
        let dictation = Self.pane(engine)
        dictation.toggle(from: try Self.key(.keyDown, at: 100))
        await until { dictation.phase == .listening }
        dictation.close()
        #expect(dictation.phase == .idle)
        await until { await engine.finishes >= 1 && !dictation.holdsResources }
    }

    /// Waits until `condition` holds. It gives up only after five seconds
    /// and 200 checks, so a main actor stalled by other tests in the full
    /// suite still gets turns to run the session.
    private func until(_ condition: @MainActor () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        var checks = 0
        while ContinuousClock.now < deadline || checks < 200 {
            if await condition() { return }
            checks += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition never held")
    }
}
