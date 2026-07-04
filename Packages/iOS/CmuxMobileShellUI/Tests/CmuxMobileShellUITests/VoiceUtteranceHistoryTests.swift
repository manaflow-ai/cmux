#if os(iOS)
import Foundation
import Testing

@testable import CmuxMobileShellUI

@Suite struct VoiceUtteranceHistoryTests {
    @Test func appendCapsHistoryNewestLast() {
        var history = VoiceUtteranceHistory(capacity: 3)

        let first = history.appendFinal(text: "one")
        let second = history.appendFinal(text: "two")
        let third = history.appendFinal(text: "three")
        let fourth = history.appendFinal(text: "four")

        #expect(history.utterances.map(\.id) == [second, third, fourth])
        #expect(history.utterance(id: first) == nil)
        #expect(history.utterances.map(\.text) == ["two", "three", "four"])
    }

    @Test func resendTransitionsAndDoubleTapGuard() {
        var history = VoiceUtteranceHistory()
        let id = history.appendFinal(text: "echo hello")

        let initialBegin = history.beginSending(id: id)
        #expect(!initialBegin, "new finals start in sending state")
        history.markFailed(id: id, message: "Check the target and speak again.", isTargetChanged: true)
        let retryBegin = history.beginSending(id: id)
        let doubleTapBegin = history.beginSending(id: id)
        #expect(retryBegin)
        #expect(!doubleTapBegin, "second tap while sending must be ignored")

        history.markSent(id: id, targetTitle: "Pane A")
        let utterance = history.utterance(id: id)
        #expect(utterance?.status == .sent(targetTitle: "Pane A"))
    }
}
#endif
