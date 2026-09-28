import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct WindowRecordingCaptionTrackTests {
    @Test func noNotesDrawNoCaption() {
        let track = WindowRecordingCaptionTrack()

        #expect(track.isEmpty)
        #expect(track.caption(atOffsetSeconds: 0) == nil)
    }

    @Test func aNoteIsDrawnFromItsOffsetUntilItExpires() {
        var track = WindowRecordingCaptionTrack(visibleSeconds: 2)
        track.append(text: "open Settings", atOffsetSeconds: 1)

        #expect(track.caption(atOffsetSeconds: 0.9) == nil)
        #expect(track.caption(atOffsetSeconds: 1) == "open Settings")
        #expect(track.caption(atOffsetSeconds: 2.9) == "open Settings")
        #expect(track.caption(atOffsetSeconds: 3) == nil)
    }

    @Test func aLaterNoteReplacesAnEarlierOneImmediately() {
        var track = WindowRecordingCaptionTrack(visibleSeconds: 10)
        track.append(text: "first", atOffsetSeconds: 0)
        track.append(text: "second", atOffsetSeconds: 1)

        #expect(track.caption(atOffsetSeconds: 0.5) == "first")
        #expect(track.caption(atOffsetSeconds: 1) == "second")
        #expect(track.count == 2)
    }

    @Test func outOfOrderNotesAreStillOrdered() {
        var track = WindowRecordingCaptionTrack(visibleSeconds: 10)
        track.append(text: "late", atOffsetSeconds: 5)
        track.append(text: "early", atOffsetSeconds: 1)

        #expect(track.notesInOrder.map(\.text) == ["early", "late"])
        #expect(track.caption(atOffsetSeconds: 2) == "early")
    }

    @Test func whitespaceIsCollapsedAndBlankNotesAreDropped() {
        var track = WindowRecordingCaptionTrack()

        let drewCaption = track.append(text: "  click\n  Settings  ", atOffsetSeconds: 0)
        let drewBlank = track.append(text: "   \n ", atOffsetSeconds: 1)

        #expect(drewCaption)
        #expect(!drewBlank)
        #expect(track.caption(atOffsetSeconds: 0) == "click Settings")
        #expect(track.count == 1)
    }

    @Test func longCaptionsAreClippedRatherThanCoveringTheWindow() {
        var track = WindowRecordingCaptionTrack()
        track.append(text: String(repeating: "a", count: 400), atOffsetSeconds: 0)
        let caption = track.caption(atOffsetSeconds: 0)

        #expect(caption?.count == WindowRecordingCaptionTrack.maximumCharacters)
        #expect(caption?.hasSuffix("\u{2026}") == true)
    }

    @Test func negativeAndBrokenOffsetsLandAtTheStart() {
        var track = WindowRecordingCaptionTrack(visibleSeconds: 5)
        track.append(text: "start", atOffsetSeconds: -3)
        track.append(text: "nan", atOffsetSeconds: .nan)

        #expect(track.notesInOrder.allSatisfy { $0.offsetSeconds == 0 })
        #expect(track.caption(atOffsetSeconds: .nan) == nil)
    }
}
