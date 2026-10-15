import Foundation
import Testing
import CmuxBrowser

@Suite("Browser page busy probe")
struct BrowserPageBusyProbeTests {
    @Test("Reads the script's JSON answer")
    func parsesAnswer() {
        #expect(BrowserPageBusyProbe.parse(#"{"media":false,"form":false}"#)
            == BrowserPageBusyProbe(playingMedia: false, editedForm: false))
        #expect(BrowserPageBusyProbe.parse(#"{"media":true,"form":false}"#)
            == BrowserPageBusyProbe(playingMedia: true, editedForm: false))
        #expect(BrowserPageBusyProbe.parse(#"{"media":false,"form":true}"#)
            == BrowserPageBusyProbe(playingMedia: false, editedForm: true))
    }

    @Test("Anything unreadable counts as busy")
    func unreadableIsBusy() {
        for value: Any? in [nil, "", "not json", #"{"media":false}"#, #"{"media":"no","form":false}"#, NSNumber(value: 1)] {
            #expect(BrowserPageBusyProbe.parse(value) == .unanswered)
        }
        #expect(BrowserPageBusyProbe.unanswered.blockers(underPressure: false) == ["media_playback", "form_input"])
    }

    @Test("Form edits yield to system memory pressure; media never does")
    func pressure() {
        let editing = BrowserPageBusyProbe(playingMedia: false, editedForm: true)
        #expect(editing.blockers(underPressure: false) == ["form_input"])
        #expect(editing.blockers(underPressure: true).isEmpty)
        let playing = BrowserPageBusyProbe(playingMedia: true, editedForm: false)
        #expect(playing.blockers(underPressure: true) == ["media_playback"])
        #expect(BrowserPageBusyProbe(playingMedia: false, editedForm: false).blockers(underPressure: false).isEmpty)
    }

    @Test("The script returns the JSON shape parse reads")
    func scriptShape() {
        #expect(BrowserPageBusyProbe.script.contains("JSON.stringify({media, form})"))
    }
}
