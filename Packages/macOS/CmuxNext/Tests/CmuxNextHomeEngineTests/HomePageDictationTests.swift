@testable import CmuxNextHome
import CmuxNextDictation
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The Messages page's mic: its calls and the updates it sends the page (the agent pane's shape,
/// which webviews agent-session dictation.ts splices).
@MainActor
struct HomePageDictationTests {
    @Test func anUpdateGoesToThePageAsTheAgentPanesShape() {
        let listening = HomePageDictation.payload(DictationUpdate(phase: .listening, text: "hello", level: 0.4567))
        #expect(listening == .object(["state": "listening", "text": "hello", "level": .number(0.457), "cancelled": .bool(false)]))
        let denied = HomePageDictation.payload(DictationUpdate(phase: .denied(.microphone)))
        #expect(denied["state"] == "denied")
        #expect(denied["permission"] == "microphone")
        #expect(denied["message"]?.stringValue == HomePageDictation.deniedMessage(.microphone))
        #expect(denied["settingsLabel"]?.stringValue == HomePageDictation.openSettingsTitle)
        #expect(HomePageDictation.payload(DictationUpdate(phase: .failed(.audioCaptureFailed("no input"))))["state"] == "failed")
    }

    @Test func openSettingsOpensThePrivacyPaneAndAnUnknownMethodIsRefused() throws {
        let dictation = HomePageDictation(claims: DictationMicrophoneClaims())
        var opened: [URL] = []
        dictation.open = { opened.append($0) }
        _ = try dictation.call(.object(["method": "dictation.openSettings", "params": .object(["permission": "speechRecognition"])]))
        #expect(opened.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"])
        // Stop and Cancel with no session do nothing; Home never sends audio.
        _ = try dictation.call(.object(["method": "dictation.stop"]))
        _ = try dictation.call(.object(["method": "dictation.audio", "params": .object(["enabled": .bool(true)])]))
        #expect(throws: PageError.self) { try dictation.call(.object(["method": "dictation.record"])) }
    }
}
