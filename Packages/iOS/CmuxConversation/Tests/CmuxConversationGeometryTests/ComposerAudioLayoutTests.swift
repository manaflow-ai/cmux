import CmuxConversationGeometry
import CoreGraphics
import Testing

/// Expected frames are Messages' own on iOS 26, read at @3x from a screen
/// recording of an audio message being recorded, reviewed and sent on a
/// 430 pt iPhone (2026-11-09): pixel edges divided by 3, in the row's
/// coordinates with the resting field ending at y = 84.
@Suite struct ComposerAudioLayoutTests {
    let oneLine: CGFloat = 20.287109375 + 20
    let width: CGFloat = 430

    func resting() -> ComposerBarGeometry.Layout {
        ComposerBarGeometry.layout(width: width, fieldBottom: 84, fieldHeight: oneLine, oneLineHeight: oneLine, sideInset: 28, scale: 3)
    }

    func layout(_ stage: ComposerAudioLayout.Stage) -> ComposerAudioLayout {
        ComposerAudioLayout(stage: stage, resting: resting(), width: width, sideInset: 28, scale: 3)
    }

    func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.67) -> Bool { abs(a - b) <= tolerance }

    /// Held (finger down): field x 72 to 409.67, 50 pt tall; stop circle
    /// 35 pt centered at x 384.83; timer ends at x 353.
    @Test func holding() {
        let l = layout(.holding)
        #expect(close(l.field.minX, 72))
        #expect(close(l.field.maxX, 409.67))
        #expect(close(l.field.height, 50))
        #expect(l.field.maxY == 84)
        #expect(l.showsLeadingButton)
        #expect(close(l.field.minX + l.stop.midX, 384.83))
        #expect(close(l.field.minX + l.timerTrailing, 353))
        #expect(close(l.field.minX + l.waveform.minX, 96, 1))
    }

    /// Recording (finger up): field x 22.67 to 410, 68.67 pt tall, "+"
    /// swallowed; stop centered at x 375.67; timer ends at 343.67; dots
    /// from 47.33 to 301.67.
    @Test func recording() {
        let l = layout(.recording)
        #expect(close(l.field.minX, 22.67))
        #expect(close(l.field.maxX, 410))
        #expect(close(l.field.height, 68.67))
        #expect(!l.showsLeadingButton)
        #expect(close(l.field.minX + l.stop.midX, 375.67))
        #expect(close(l.stop.width, 35.67))
        #expect(close(l.stopSquare.width, 11.33))
        #expect(close(l.field.minX + l.timerTrailing, 343.67))
        #expect(close(l.field.minX + l.waveform.minX, 47.33))
        #expect(close(l.field.minX + l.waveform.maxX, 301.67))
        #expect(close(l.stop.midY, l.field.height / 2))
    }

    /// Review: field x 81 to 402, 66.33 pt tall; "x" 40 pt at the "+"'s x,
    /// centered on the field; play 34.33 pt at 97; waveform 147.33 to
    /// 260.67; pill 273.33 to 332.33 (25.33 tall); send 344.67 to 382.67.
    @Test func review() {
        let l = layout(.review)
        #expect(close(l.field.minX, 80.67, 1))
        #expect(close(l.field.maxX, 402))
        #expect(close(l.field.height, 66.33))
        #expect(l.showsLeadingButton)
        #expect(l.leadingButton.minX == 28)
        #expect(close(l.leadingButton.midY, l.field.midY, 0.34))
        let x = l.field.minX
        #expect(close(x + l.play.minX, 97))
        #expect(close(l.play.width, 34.33))
        #expect(close(x + l.waveform.minX, 147.33))
        #expect(close(x + l.waveform.maxX, 260.67))
        #expect(close(x + l.pill.minX, 273.33))
        #expect(close(x + l.pill.maxX, 332.33))
        #expect(close(l.pill.height, 25.33))
        #expect(close(x + l.send.minX, 344.67))
        #expect(l.send.size == CGSize(width: 38, height: 28))
        #expect(close(l.send.midY, l.field.height / 2, 0.34))
    }

    /// Every stage keeps the field's bottom on the resting field's bottom
    /// and grows upward, as Messages does.
    @Test func growsUpward() {
        for stage in [ComposerAudioLayout.Stage.holding, .recording, .review] {
            #expect(layout(stage).field.maxY == resting().field.maxY)
        }
    }

    /// Bars: 2 pt on a 4 pt pitch; silence is a 4 pt dot.
    @Test func bars() {
        #expect(ComposerAudioLayout.barCount(width: 254.33) == 64)
        #expect(ComposerAudioLayout.barHeight(level: 0, band: 24) == 4)
        #expect(ComposerAudioLayout.barHeight(level: 1, band: 24) == 24)
    }
}

/// Messages' record button: a tap shows the hint, a hold records and stays
/// recording when the finger lifts, stop opens the review. The composer
/// used to start on a tap and stop to review on release.
@Suite struct ComposerAudioFlowTests {
    @Test func tapShowsHintAndDoesNotRecord() {
        var flow = ComposerAudioFlow()
        #expect(flow.handle(.tap(voiceOver: false)) == [.showHoldHint])
        #expect(flow.stage == nil)
        #expect(!flow.isActive)
    }

    @Test func holdRecordsAndReleaseLocksIt() {
        var flow = ComposerAudioFlow()
        #expect(flow.handle(.holdBegan) == [.startRecording])
        #expect(flow.stage == .holding)
        flow.handle(.recorderStarted)
        #expect(flow.stage == .holding)
        // Lifting the finger keeps recording; it does not stop to review.
        #expect(flow.handle(.holdEnded) == [])
        #expect(flow.stage == .recording)
        #expect(flow.handle(.stop(longEnough: true)) == [.pauseRecording])
        #expect(flow.stage == .review)
        #expect(flow.handle(.continueRecording) == [.resumeRecording])
        #expect(flow.stage == .recording)
        flow.handle(.stop(longEnough: true))
        #expect(flow.handle(.send) == [.sendRecording])
        #expect(flow.stage == nil)
    }

    /// The finger lifts while the microphone permission prompt is up: the
    /// recording locks open once the microphone runs.
    @Test func releaseBeforeMicrophoneLocksOnStart() {
        var flow = ComposerAudioFlow()
        flow.handle(.holdBegan)
        flow.handle(.holdEnded)
        #expect(flow.stage == .holding)
        flow.handle(.recorderStarted)
        #expect(flow.stage == .recording)
    }

    @Test func shortRecordingIsDiscarded() {
        var flow = ComposerAudioFlow()
        flow.handle(.holdBegan)
        flow.handle(.recorderStarted)
        #expect(flow.handle(.stop(longEnough: false)) == [.pauseRecording, .discard])
        #expect(flow.stage == nil)
    }

    @Test func cancelFromReviewDiscards() {
        var flow = ComposerAudioFlow()
        flow.handle(.holdBegan)
        flow.handle(.recorderStarted)
        flow.handle(.holdEnded)
        flow.handle(.stop(longEnough: true))
        #expect(flow.handle(.cancel) == [.discard])
        #expect(flow.stage == nil)
    }

    /// Recording more fails to start: back to the review, where stop is not
    /// needed and the x still discards (the recording stage has no x).
    @Test func failedResumeReturnsToReview() {
        var flow = ComposerAudioFlow()
        flow.handle(.holdBegan)
        flow.handle(.recorderStarted)
        flow.handle(.holdEnded)
        flow.handle(.stop(longEnough: true))
        flow.handle(.continueRecording)
        #expect(flow.handle(.resumeFailed) == [])
        #expect(flow.stage == .review)
        #expect(flow.handle(.cancel) == [.discard])
    }

    @Test func voiceOverActivationRecordsLocked() {
        var flow = ComposerAudioFlow()
        #expect(flow.handle(.tap(voiceOver: true)) == [.startRecording])
        #expect(flow.stage == .recording)
        flow.handle(.recorderStarted)
        #expect(flow.stage == .recording)
    }

    /// A second hold while one is recording does nothing.
    @Test func secondHoldIgnored() {
        var flow = ComposerAudioFlow()
        flow.handle(.holdBegan)
        #expect(flow.handle(.holdBegan) == [])
        #expect(flow.handle(.tap(voiceOver: false)) == [])
    }
}
