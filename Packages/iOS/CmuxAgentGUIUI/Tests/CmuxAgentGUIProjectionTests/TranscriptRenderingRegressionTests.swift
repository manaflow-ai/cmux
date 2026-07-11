#if os(iOS)
@testable import CmuxAgentGUIUI
import Testing
import UIKit

@Suite @MainActor struct TranscriptRenderingRegressionTests {
    @Test func chromePassesBackgroundTouchesToTranscript() {
        let chrome = TranscriptChromePassthroughView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        let control = UIButton(frame: CGRect(x: 220, y: 520, width: 60, height: 44))
        chrome.addSubview(control)

        #expect(chrome.hitTest(CGPoint(x: 40, y: 200), with: nil) == nil)
        #expect(chrome.hitTest(CGPoint(x: 240, y: 540), with: nil) === control)
    }

    @Test func tallFixtureAndBurstAppendImmediatelyUpdateProjection() {
        let model = TranscriptDemoModel()

        model.setTallFixtureEnabled(true)
        #expect(model.input.entries.count == 220)

        model.appendBurstRows()
        #expect(model.input.entries.count == 225)
    }
}
#endif
